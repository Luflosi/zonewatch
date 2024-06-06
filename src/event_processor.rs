// SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
// SPDX-License-Identifier: GPL-3.0-only

use crate::config;
use crate::db;
use crate::event_analyzer::Changes;
use crate::reloader::Reloader;
use crate::zone_file;
use color_eyre::eyre::{Result, WrapErr};
use log::{debug, info, trace};
use sqlx::{Pool, Sqlite};

pub async fn process_probably_changed_includes(
	zone_name: &str,
	config_zone: &config::Zone,
	changes: Changes,
	reloader: &Reloader,
	force_write: bool,
	pool: &Pool<Sqlite>,
) -> Result<()> {
	let mut tx = pool.begin().await.wrap_err("Cannot begin transaction")?;

	let maybe_old_zone = db::read_zone(zone_name, &mut tx)
		.await
		.wrap_err("Cannot read zone info")?;

	let (serial, includes) = match &maybe_old_zone {
		Some(old_zone) => {
			let includes = match changes {
				Changes::All => {
					debug!("Will rescan all the files");
					zone_file::Include::files_from_paths(config_zone.includes.iter())
						.wrap_err("Cannot construct Include from include path")
				}
				Changes::Some(changed_include_paths) => {
					debug!("This is the set of changed files: {changed_include_paths:?}");
					let changed_files =
						zone_file::Include::files_from_paths(changed_include_paths.iter())
							.wrap_err("Cannot convert include path to Include")?;
					let mut includes = old_zone.includes.clone();
					includes.extend(changed_files);
					Ok(includes)
				}
				Changes::None => Ok(old_zone.includes.clone()),
			}
			.wrap_err("Cannot convert include path to Include")?;

			(old_zone.soa.serial, includes)
		}
		None => {
			let serial = config_zone.soa.initial_serial;
			info!(
				"Zone does not exist yet, generating new zone file with serial {}",
				serial
			);
			let includes = zone_file::Include::files_from_paths(config_zone.includes.iter())
				.wrap_err("Cannot convert include path to Include")?;
			(serial, includes)
		}
	};

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
	let mut new_zone = zone_file::Zone {
		name: zone_name.to_string(),
		dir: config_zone.dir.clone(),
		ttl: config_zone.ttl.clone(),
		includes,
		includes_ordered: config_zone.includes.clone(),
		soa,
	};

	match maybe_old_zone {
		None => {
			info!("Writing zone file for the first time");
			zone_file::sync_state_to_disc(new_zone, reloader, &mut tx).await?;
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
					info!("Writing zone file even though nothing was changed");
					zone_file::sync_state_to_disc(new_zone, reloader, &mut tx).await?;
				} else {
					info!(
						"No contents of any file actually changed for zone {zone_name}, ignoring"
					);
				}
			} else {
				let serial = new_zone.soa.serial.wrapping_add(1);
				info!("Something changed, generating new zone file and incrementing serial to {serial}");
				new_zone.soa.serial = serial;

				zone_file::sync_state_to_disc(new_zone, reloader, &mut tx).await?;
			}
		}
	}

	tx.commit().await.wrap_err("Cannot commit transaction")?;

	Ok(())
}
