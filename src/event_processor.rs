// SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
// SPDX-License-Identifier: GPL-3.0-only

use crate::config;
use crate::db;
use crate::event_analyzer::Changes;
use crate::reloader::Reloader;
use crate::zone_file;
use color_eyre::eyre::{Result, WrapErr};
use log::{debug, info, trace};
use sqlx::{Pool, Sqlite, Transaction};

fn update_zone(
	zone_name: &str,
	config_zone: &config::Zone,
	changes: Changes,
	maybe_old_zone: Option<&zone_file::Zone>,
) -> zone_file::Zone {
	let (serial, includes) = maybe_old_zone.as_ref().map_or_else(
		|| {
			let serial = config_zone.soa.initial_serial;
			info!("Zone does not exist yet, generating new zone file with serial {serial}");
			let includes = zone_file::Include::files_from_paths(config_zone.includes.iter());
			(serial, includes)
		},
		|old_zone| {
			let includes = match changes {
				Changes::All => {
					debug!("Will rescan all the files");
					zone_file::Include::files_from_paths(config_zone.includes.iter())
				}
				Changes::Some(changed_include_paths) => {
					debug!("This is the set of changed files: {changed_include_paths:?}");
					let changed_files =
						zone_file::Include::files_from_paths(changed_include_paths.iter());
					let mut includes = old_zone.includes.clone();
					includes.extend(changed_files);
					includes
				}
				Changes::None => old_zone.includes.clone(),
			};

			(old_zone.soa.serial, includes)
		},
	);

	let soa = zone_file::Soa {
		ttl: config_zone.soa.ttl.clone(),
		mname: config_zone.soa.mname.clone(),
		rname: config_zone.soa.rname.clone(),
		serial,
		refresh: config_zone.soa.refresh.clone(),
		retry: config_zone.soa.retry.clone(),
		expire: config_zone.soa.expire.clone(),
		minimum: config_zone.soa.minimum.clone(),
	};
	zone_file::Zone {
		name: zone_name.to_string(),
		dir: config_zone.dir.clone(),
		ttl: config_zone.ttl.clone(),
		includes,
		includes_ordered: config_zone.includes.clone(),
		soa,
	}
}

// Returns true if the reload program needs to be executed
async fn write_state(
	// add needs_reloading to the name
	zone_name: &str,
	force_write: bool,
	mut new_zone: zone_file::Zone,
	maybe_old_zone: Option<zone_file::Zone>,
	tx: &mut Transaction<'_, Sqlite>,
) -> Result<bool> {
	let needs_reloading = match maybe_old_zone {
		None => {
			info!("Writing zone file for the first time");
			zone_file::sync_state_to_disc(new_zone, tx).await?;
			true
		}
		Some(old_zone) => {
			trace!("old_zone: {old_zone:?}");
			trace!("new_zone: {new_zone:?}");
			if new_zone == old_zone {
				if force_write {
					// It may have happened that zonewatch was shut down after the
					// database was written (with a new serial number) but before the zone file was written.
					// If this happens, the serial number is inconsistent between the zone file and the database.
					// To fix this, I could call fsync(). But since I can also just regenerate the file
					// every time this program starts, I'll avoid learning the semantics
					// of fsync() on every filesystem and just write the zone file again after each start.
					info!("Writing zone file even though nothing changed");
					zone_file::sync_state_to_disc(new_zone, tx).await?;
					true
				} else {
					info!(
						"No contents of any file actually changed for zone {zone_name}, ignoring"
					);
					false
				}
			} else {
				let serial = new_zone.soa.serial.wrapping_add(1);
				info!("Something changed, generating new zone file and incrementing serial to {serial}");
				new_zone.soa.serial = serial;

				zone_file::sync_state_to_disc(new_zone, tx).await?;
				true
			}
		}
	};
	Ok(needs_reloading)
}

pub async fn process_probably_changed_includes(
	zone_name: &str,
	config_zone: &config::Zone,
	changes: Changes,
	reloader: &Reloader,
	force_write: bool,
	pool: &Pool<Sqlite>,
) -> Result<()> {
	trace!("Will begin transaction");
	let mut tx = pool.begin().await.wrap_err("Cannot begin transaction")?;
	trace!("Transaction began");

	let maybe_old_zone = db::read_zone(zone_name, &mut tx)
		.await
		.wrap_err("Cannot read zone info")?;

	let new_zone = update_zone(zone_name, config_zone, changes, maybe_old_zone.as_ref());
	let needs_reloading =
		write_state(zone_name, force_write, new_zone, maybe_old_zone, &mut tx).await?;

	trace!("Will end transaction");
	tx.commit().await.wrap_err("Cannot commit transaction")?;
	trace!("Transaction ended");

	// Reload only after committing the transaction.
	// If the reload command fails, the updated zone file was already written to disk
	// and the DNS server may have already seen the incremented serial number.
	// For this reason we have to keep the new serial number.
	if needs_reloading {
		trace!("Will execute the reloading program");
		reloader.execute()?;
		trace!("Done executing the reloading program");
	} else {
		trace!("We don't need to call the reloading program");
	}

	Ok(())
}
