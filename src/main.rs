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
use color_eyre::eyre::{eyre, Error, Result, WrapErr};
use log::{error, info};
use std::thread;

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

// This function is from https://stackoverflow.com/questions/62700780/using-error-chain-with-joinhandle
fn chain_any(
	x: std::result::Result<
		std::result::Result<(), Error>,
		std::boxed::Box<dyn std::any::Any + std::marker::Send>,
	>,
) -> Result<()> {
	match x {
		// Child did not panic, but might have thrown an error.
		Ok(x) => x.wrap_err("Child threw an error")?,

		// Child panicked, let's try to print out the reason why.
		Err(e) => {
			error!("{:?}", e.type_id());
			if let Some(s) = e.downcast_ref::<&str>() {
				return Err(eyre!("Child panicked with this message:\n{}", s));
			} else if let Some(s) = e.downcast_ref::<String>() {
				return Err(eyre!("Child panicked with this message:\n{}", s));
			}
			return Err(eyre!(
				"Child panicked! Not sure why, here's the panic:\n{:?}",
				e
			));
		}
	}
	Ok(())
}

#[tokio::main()]
async fn main() -> Result<()> {
	color_eyre::install()?;

	logging::setup();

	let args = Args::parse();

	let config = Config::read(&args.config).wrap_err("Cannot read config file")?;

	let pool = db::init(&config.db).await?;

	let handles: Vec<_> = config
		.zones
		.into_iter()
		.map(|(origin, zone)| {
			info!("Starting Thread {origin}");
			let builder = thread::Builder::new().name(origin.clone());
			// TODO: find a way to pass these variables without .clone()
			let pool_for_thread = pool.clone();
			let nix_dir = config.nix_dir.clone();
			let reloader = Reloader {
				bin: config.reload_program_bin.clone(),
				args: zone.reload_program_args.clone(),
			};
			let only_init = args.only_init;
			builder.spawn(move || {
				info!("Thread {origin} started");
				watch(
					pool_for_thread,
					&nix_dir,
					&origin,
					zone,
					reloader,
					only_init,
				)
				.wrap_err_with(|| format!("While watching zone `{origin}`"))
			})
		})
		.collect();
	for handle in handles {
		let handle = handle.wrap_err("Thread Builder returned error while spawning thread")?;
		chain_any(handle.join()).wrap_err("Cannot join child thread")?;
	}

	Ok(())
}
