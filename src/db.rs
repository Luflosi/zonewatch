// SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
// SPDX-License-Identifier: GPL-3.0-only

use crate::zone_file;
use blake3::Hash;
use color_eyre::eyre::{eyre, Result, WrapErr};
use futures::StreamExt;
use indoc::indoc;
use log::debug;
use sqlx::{
	sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions},
	Pool, Row, Sqlite, Transaction,
};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{error::Error, fmt::Debug};

#[derive(sqlx::FromRow)]
struct Zone {
	name: String,
	dir: String,
	ttl: String,
	soa_ttl: String,
	soa_mname: String,
	soa_rname: String,
	soa_serial: i64,
	soa_refresh: String,
	soa_retry: String,
	soa_expire: String,
	soa_minimum: String,
}

#[derive(sqlx::FromRow)]
struct Include {
	path: String,
	hash: Option<Vec<u8>>,
	error: Option<i64>,
}

struct PartialInclude {
	hash: Option<Vec<u8>>,
	error: Option<i64>,
}

impl TryFrom<Zone> for zone_file::Soa {
	type Error = <u32 as TryFrom<i64>>::Error;

	fn try_from(zone: Zone) -> std::result::Result<Self, Self::Error> {
		let soa = Self {
			serial: zone.soa_serial.try_into()?,
			ttl: zone.soa_ttl,
			mname: zone.soa_mname,
			rname: zone.soa_rname,
			refresh: zone.soa_refresh,
			retry: zone.soa_retry,
			expire: zone.soa_expire,
			minimum: zone.soa_minimum,
		};
		Ok(soa)
	}
}

#[derive(thiserror::Error)]
pub enum IncludeConvertError {
	#[error("hash is not 32 bytes long")]
	InvalidHashLength(#[source] std::array::TryFromSliceError),

	#[error("failed to convert the file read error")]
	FileReadConvert,

	#[error("neither hash nor error were set")]
	HashAndErrorNotSet,

	#[error("both hash and error were set")]
	HashAndErrorBothSet,
}

impl Debug for IncludeConvertError {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		writeln!(f, "{self}")?;
		if let Some(source) = self.source() {
			writeln!(f, "Caused by:\n\t{source}")?;
		}
		Ok(())
	}
}

impl TryFrom<Include> for zone_file::Include {
	type Error = IncludeConvertError;

	fn try_from(include: Include) -> std::result::Result<Self, Self::Error> {
		use zone_file::Include::Readable;
		match (include.hash, include.error) {
			(Some(hash), None) => {
				let hash: [u8; 32] = hash[..]
					.try_into()
					.map_err(IncludeConvertError::InvalidHashLength)?;
				Ok(Readable(Hash::from_bytes(hash)))
			}
			(None, Some(error)) => error.try_into(),
			(Some(_), Some(_)) => Err(IncludeConvertError::HashAndErrorBothSet),
			(None, None) => Err(IncludeConvertError::HashAndErrorNotSet),
		}
	}
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum IncludeError {
	NotFound = 1,
	PermissionDenied = 2,
	OtherError = 0,
}

impl TryFrom<i64> for zone_file::Include {
	type Error = IncludeConvertError;

	fn try_from(e: i64) -> Result<Self, Self::Error> {
		use zone_file::Include::{NotFound, OtherError, PermissionDenied};
		match e {
			x if x == IncludeError::OtherError as i64 => Ok(OtherError),
			x if x == IncludeError::NotFound as i64 => Ok(NotFound),
			x if x == IncludeError::PermissionDenied as i64 => Ok(PermissionDenied),
			_ => Err(IncludeConvertError::FileReadConvert),
		}
	}
}

impl From<&zone_file::Include> for PartialInclude {
	fn from(include: &zone_file::Include) -> Self {
		use zone_file::Include::{NotFound, OtherError, PermissionDenied, Readable};
		match include {
			Readable(hash) => Self {
				hash: Some(hash.as_bytes().to_vec()),
				error: None,
			},
			OtherError => Self {
				hash: None,
				error: Some(IncludeError::OtherError as i64),
			},
			NotFound => Self {
				hash: None,
				error: Some(IncludeError::NotFound as i64),
			},
			PermissionDenied => Self {
				hash: None,
				error: Some(IncludeError::PermissionDenied as i64),
			},
		}
	}
}

fn db_to_zone(
	db_zone: Zone,
	(includes, includes_ordered): (HashMap<PathBuf, zone_file::Include>, Vec<PathBuf>),
) -> Result<zone_file::Zone> {
	let name = db_zone.name.clone();
	let dir = PathBuf::from(&db_zone.dir);
	let ttl = db_zone.ttl.clone();
	let soa: zone_file::Soa = db_zone
		.try_into()
		.wrap_err("Cannot construct Soa struct from information from the database")?;

	let zone = zone_file::Zone {
		name,
		dir,
		ttl,
		includes,
		includes_ordered,
		soa,
	};
	Ok(zone)
}

pub async fn init(path: &Path) -> Result<Pool<Sqlite>> {
	let connection_options = SqliteConnectOptions::new()
		.filename(path)
		.create_if_missing(true)
		.journal_mode(SqliteJournalMode::Wal)
		.optimize_on_close(true, None);

	let pool = SqlitePoolOptions::new()
		.max_connections(1)
		.connect_with(connection_options)
		.await
		.wrap_err_with(|| format!("Cannot open database file `{}`", path.display()))?;

	sqlx::migrate!("./migrations")
		.run(&pool)
		.await
		.wrap_err("Cannot run database migrations")?;

	Ok(pool)
}

async fn read_includes(
	zoneid: i64,
	tx: &mut Transaction<'_, Sqlite>,
) -> Result<(HashMap<PathBuf, zone_file::Include>, Vec<PathBuf>)> {
	let mut includes_rows = sqlx::query_as::<_, Include>(indoc! {"
		SELECT
			id,
			zoneid,
			path,
			hash,
			error
		FROM includes
		WHERE zoneid = ?1
		ORDER BY id;
	"})
	.bind(zoneid)
	.fetch(&mut **tx);

	let mut includes: HashMap<PathBuf, zone_file::Include> = HashMap::new();
	let mut includes_ordered: Vec<PathBuf> = Vec::new();
	while let Some(maybe_include_row) = includes_rows.next().await {
		let include_row = maybe_include_row.wrap_err("Cannot get row from includes table")?;
		let path = PathBuf::from(&include_row.path);
		let include: zone_file::Include = include_row
			.try_into()
			.wrap_err("Cannot convert database information to Include struct")?;

		includes.insert(path.clone(), include);
		includes_ordered.push(path);
	}

	Ok((includes, includes_ordered))
}

async fn get_zone_id(zone_name: &str, tx: &mut Transaction<'_, Sqlite>) -> Result<Option<i64>> {
	let maybe_zone_row = sqlx::query(indoc! {"
		SELECT id FROM zones WHERE name = ?1;
	"})
	.bind(zone_name)
	.fetch_optional(&mut **tx)
	.await
	.wrap_err("Cannot SELECT id from zones table")?;

	match maybe_zone_row {
		None => Ok(None),
		Some(zone_row) => {
			let id: i64 = zone_row
				.try_get("id")
				.wrap_err("Cannot get id from zones table")?;
			Ok(Some(id))
		}
	}
}

fn path_buf_to_string(path: &Path) -> Result<String> {
	path.to_str().map_or_else(
		|| Err(eyre!("path is not valid unicode: {}", path.display())),
		|path| Ok(path.to_string()),
	)
}

async fn insert_zone(zone: &zone_file::Zone, tx: &mut Transaction<'_, Sqlite>) -> Result<()> {
	let zone_dir = path_buf_to_string(&zone.dir).wrap_err("Cannot convert zone dir to string")?;

	sqlx::query(indoc! {"
		INSERT INTO zones (
			name,
			dir,
			ttl,
			soa_ttl,
			soa_mname,
			soa_rname,
			soa_serial,
			soa_refresh,
			soa_retry,
			soa_expire,
			soa_minimum
		)
		VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
	"})
	.bind(&zone.name)
	.bind(zone_dir)
	.bind(&zone.ttl)
	.bind(&zone.soa.ttl)
	.bind(&zone.soa.mname)
	.bind(&zone.soa.rname)
	.bind(zone.soa.serial)
	.bind(&zone.soa.refresh)
	.bind(&zone.soa.retry)
	.bind(&zone.soa.expire)
	.bind(&zone.soa.minimum)
	.execute(&mut **tx)
	.await
	.wrap_err("Cannot INSERT into zones table")?;

	Ok(())
}

async fn update_zone(
	zoneid: i64,
	zone: &zone_file::Zone,
	tx: &mut Transaction<'_, Sqlite>,
) -> Result<()> {
	let zone_dir = path_buf_to_string(&zone.dir).wrap_err("Cannot convert zone dir to string")?;

	// TODO: only update what actually changed?
	sqlx::query(indoc! {"
		UPDATE zones SET
			name = ?2,
			dir = ?3,
			ttl = ?4,
			soa_ttl = ?5,
			soa_mname = ?6,
			soa_rname = ?7,
			soa_serial = ?8,
			soa_refresh = ?9,
			soa_retry = ?10,
			soa_expire = ?11,
			soa_minimum = ?12
		WHERE id = ?1;
	"})
	.bind(zoneid)
	.bind(&zone.name)
	.bind(zone_dir)
	.bind(&zone.ttl)
	.bind(&zone.soa.ttl)
	.bind(&zone.soa.mname)
	.bind(&zone.soa.rname)
	.bind(zone.soa.serial)
	.bind(&zone.soa.refresh)
	.bind(&zone.soa.retry)
	.bind(&zone.soa.expire)
	.bind(&zone.soa.minimum)
	.execute(&mut **tx)
	.await
	.wrap_err("Cannot UPDATE zones table")?;

	Ok(())
}

pub async fn read_zone(
	zone_name: &str,
	tx: &mut Transaction<'_, Sqlite>,
) -> Result<Option<zone_file::Zone>> {
	let maybe_zoneid = get_zone_id(zone_name, tx)
		.await
		.wrap_err("Cannot get the Zone ID from the database")?;

	let zoneid = match maybe_zoneid {
		None => return Ok(None),
		Some(zoneid) => zoneid,
	};

	let zone = sqlx::query_as::<_, Zone>(indoc! {"
		SELECT
			name,
			dir,
			ttl,
			soa_ttl,
			soa_mname,
			soa_rname,
			soa_serial,
			soa_refresh,
			soa_retry,
			soa_expire,
			soa_minimum
		FROM zones
		WHERE id = ?1;
	"})
	.bind(zoneid)
	.fetch_one(&mut **tx)
	.await
	.wrap_err("Cannot SELECT row from zones table")?;

	let includes = read_includes(zoneid, tx)
		.await
		.wrap_err("Cannot read includes from database")?;

	let zone = db_to_zone(zone, includes)
		.wrap_err("Cannot convert database information to zone struct")?;

	Ok(Some(zone))
}

pub async fn write_state(zone: &zone_file::Zone, tx: &mut Transaction<'_, Sqlite>) -> Result<()> {
	let maybe_zoneid = get_zone_id(&zone.name, tx)
		.await
		.wrap_err("Cannot get the Zone ID from the database")?;

	let zoneid = match maybe_zoneid {
		None => {
			insert_zone(zone, tx).await?;

			let maybe_zoneid = get_zone_id(&zone.name, tx)
				.await
				.wrap_err("Cannot get the Zone ID from the database")?;

			maybe_zoneid.expect("We just inserted a new row in the database with this name, so selecting it right afterwards should never fail")
		}
		Some(zoneid) => {
			update_zone(zoneid, zone, tx).await?;

			zoneid
		}
	};

	let (old_includes, old_includes_ordered) = read_includes(zoneid, tx)
		.await
		.wrap_err("Cannot read includes from database")?;

	let new_includes = &zone.includes;
	let new_includes_ordered = &zone.includes_ordered;

	if *new_includes == old_includes && *new_includes_ordered == old_includes_ordered {
		debug!("Nothing about the includes changed, not saving into database");
	} else {
		debug!("Something about the includes changed, saving into database");
		sqlx::query(indoc! {"
			DELETE FROM includes
			WHERE zoneid = ?1;
		"})
		.bind(zoneid)
		.execute(&mut **tx)
		.await
		.wrap_err("Cannot DELETE from includes table")?;

		for path in new_includes_ordered {
			let include = new_includes
				.get(path)
				.expect("new_includes should contain the same keys as new_includes_ordered");
			let path_str = path_buf_to_string(path)
				.wrap_err("Cannot convert path of added include to string")?;

			let partial_include: PartialInclude = include.into();

			sqlx::query(indoc! {"
				INSERT INTO includes (
					zoneid,
					path,
					hash,
					error
				)
				VALUES (?1, ?2, ?3, ?4);
			"})
			.bind(zoneid)
			.bind(path_str)
			.bind(partial_include.hash)
			.bind(partial_include.error)
			.execute(&mut **tx)
			.await
			.wrap_err("Cannot INSERT into includes table")?;
		}
	}

	Ok(())
}
