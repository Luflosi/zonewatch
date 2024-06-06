// SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
// SPDX-License-Identifier: GPL-3.0-only

use crate::config;
use crate::event_analyzer::{analyze_event, Changes};
use crate::event_processor::process_probably_changed_includes;
use crate::reloader::Reloader;
use color_eyre::eyre::{eyre, Result, WrapErr};
use log::{debug, trace};
use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use sqlx::{Pool, Sqlite};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use tokio::{
	sync::mpsc::channel,
	time::{timeout_at, Duration, Instant},
};

// TODO: make timeout configurable
const DEBOUNCE_TIME: Duration = Duration::from_millis(100);

fn detect_change(
	includes: &HashSet<PathBuf>,
	res: Option<notify::Result<Event>>,
	changes: Changes,
) -> Result<Changes> {
	if let Some(event) = res {
		let event = event.wrap_err("Error from RecommendedWatcher")?;
		let new_changes = analyze_event(includes, event);
		return Ok(changes.union(new_changes));
	}

	Ok(changes)
}

async fn async_watch(
	pool: Pool<Sqlite>,
	nix_dir: &Path,
	zone_name: &str,
	zone: config::Zone,
	reloader: Reloader,
	only_init: bool,
) -> Result<()> {
	let (tx, mut rx) = channel(1);

	let mut watcher = RecommendedWatcher::new(
		move |res| {
			futures::executor::block_on(async {
				tx.send(res)
					.await
					.expect("could not send event into channel");
			});
		},
		Config::default(),
	)
	.wrap_err("Cannot create watcher")?;

	if !only_init {
		let include_parent_dirs: Result<HashSet<PathBuf>> = zone
			.includes
			.iter()
			.map(|path| {
				path.parent().map_or_else(
					|| {
						Err(eyre!(format!(
							"Cannot get the parent directory of path `{}`",
							path.display()
						)))
					},
					|dir| Ok(dir.to_path_buf()),
				)
			})
			.collect();

		for dir in include_parent_dirs? {
			if dir.starts_with(nix_dir) {
				// Special case for files in the Nix Store:
				// The contents of files in the Nix Store will never change since the files in the Nix store are immutable.
				debug!("Not watching {} since it's in the Nix store", dir.display());
			} else {
				trace!("Watching {}", dir.display());
				watcher
					// We're watching the parent directories of files so that we can also observe if the file is renamed, created or deleted
					.watch(dir.as_ref(), RecursiveMode::NonRecursive)
					.wrap_err_with(|| format!("Cannot start watching path `{}`", dir.display()))?;
			}
		}
	}

	process_probably_changed_includes(zone_name, &zone, Changes::All, &reloader, true, &pool)
		.await?;

	if only_init {
		return Ok(());
	}

	loop {
		// Wait til some file we're interested in changes
		let mut changes = Changes::None;
		loop {
			let res = rx.recv().await;
			changes = detect_change(&zone.includes_set, res, changes)?;
			match &changes {
				Changes::Some(_) | Changes::All => {
					break;
				}
				Changes::None => {
					continue;
				}
			}
		}

		trace!(
			"Received first event, waiting for other events for {:?}",
			DEBOUNCE_TIME
		);

		let start_time = Instant::now();
		let end_time = start_time + DEBOUNCE_TIME;
		// Then wait a certain amount of time and keep track of the set of changed files in that time window

		// TODO: figure out a way to only catch the Elapsed(()) error
		// Unfortunately the tuple inside is private, so I cannot match on this struct
		// As a workaround, assume this is the only possible "error"
		// The documentation at https://docs.rs/tokio/latest/tokio/time/fn.timeout_at.html also catches all errors
		//Err(Elapsed(_)) => todo!(),
		while let Ok(event) = timeout_at(end_time, rx.recv()).await {
			changes = detect_change(&zone.includes_set, event, changes)?;
		}
		debug!("We waited long enough");
		// Finally generate a new zone file
		if changes == Changes::None {
			return Err(eyre!(
				"This code should never be executed (there were no changes)"
			));
		}
		process_probably_changed_includes(zone_name, &zone, changes, &reloader, false, &pool)
			.await
			.wrap_err("Cannot process probably changed includes")?;

		trace!("loop");
	}
}

#[tokio::main()]
pub async fn watch(
	pool: Pool<Sqlite>,
	nix_dir: &Path,
	zone_name: &str,
	zone: config::Zone,
	reloader: Reloader,
	only_init: bool,
) -> Result<()> {
	futures::executor::block_on(async_watch(
		pool, nix_dir, zone_name, zone, reloader, only_init,
	))
}
