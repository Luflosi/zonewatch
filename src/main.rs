// SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
// SPDX-License-Identifier: GPL-3.0-only

mod config;
mod db;
mod event_analyzer;
mod event_processor;
mod logging;
mod reloader;
mod watcher;
mod zone_file;

use crate::config::Config;
use crate::reloader::Reloader;
use crate::watcher::watch;
use clap::Parser;
use color_eyre::eyre::{Result, WrapErr};
use log::info;
use tokio::task::JoinSet;

#[derive(Parser, Debug)]
#[command(version)]
struct Args {
	/// Path to the config file
	#[arg(short, long, default_value = "config.toml")]
	config: std::path::PathBuf,

	/// Whether to only generate the initial zone file and then exit, mainly used for testing
	#[arg(long, action)]
	only_init: bool,
}

#[tokio::main()]
async fn main() -> Result<()> {
	color_eyre::install()?;

	logging::setup();

	let args = Args::parse();

	let config = Config::read(&args.config).wrap_err("Cannot read config file")?;

	let pool = db::init(&config.db).await?;

	let mut set = JoinSet::new();

	for (origin, zone) in config.zones {
		info!("Starting task for zone {origin}");
		// TODO: find a way to pass these variables without .clone()
		let pool_for_thread = pool.clone();
		let nix_dir = config.nix_dir.clone();
		let reloader = Reloader {
			zone_name: origin.clone(),
			bin: config.reload_program_bin.clone(),
			args: zone.reload_program_args.clone(),
		};
		let only_init = args.only_init;
		set.spawn(async move {
			info!("Task for zone {origin} started");
			watch(
				pool_for_thread,
				&nix_dir,
				&origin,
				zone,
				reloader,
				only_init,
			)
			.await
			.wrap_err_with(|| format!("While watching zone `{origin}`"))
		});
	}

	while let Some(res) = set.join_next().await {
		let inner_res = res.wrap_err("While joining all tasks")?;
		inner_res?;
	}

	Ok(())
}
