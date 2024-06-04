// SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
// SPDX-License-Identifier: GPL-3.0-only

use color_eyre::eyre::{Result, WrapErr};
use log::info;
use serde_derive::Deserialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
pub struct Raw {
	pub db: PathBuf,
	pub nix_dir: Option<PathBuf>,
	pub reload_program_bin: PathBuf,
	pub zones: HashMap<String, ZoneRaw>,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct ZoneRaw {
	pub dir: PathBuf,
	pub reload_program_args: Vec<String>,
	pub ttl: String,
	pub includes: Vec<PathBuf>,
	pub soa: Soa,
}

#[derive(Debug, Deserialize, PartialEq, Eq, Clone)]
pub struct Soa {
	pub ttl: String,
	pub mname: String,
	pub rname: String,
	pub refresh: String,
	pub retry: String,
	pub expire: String,
	pub minimum: String,
}

#[derive(Debug)]
pub struct Config {
	pub db: PathBuf,
	pub nix_dir: PathBuf,
	pub reload_program_bin: PathBuf,
	pub zones: HashMap<String, Zone>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Zone {
	pub dir: PathBuf,
	pub reload_program_args: Vec<String>,
	pub ttl: String,
	pub includes: Vec<PathBuf>,
	pub includes_set: HashSet<PathBuf>,
	pub soa: Soa,
}

impl Config {
	pub fn read(filename: &Path) -> Result<Self> {
		info!("Reading config file {}", filename.display());
		let contents = fs::read_to_string(filename)
			.wrap_err_with(|| format!("Cannot read config file `{}`", filename.display()))?;
		Self::parse(&contents)
			.wrap_err_with(|| format!("Cannot parse config file `{}`", filename.display()))
	}

	fn parse(contents: &str) -> Result<Self> {
		let raw_config: Raw = toml::from_str(contents)?;
		Ok(raw_config.try_into()?)
	}
}

#[derive(thiserror::Error, Debug)]
pub enum ConvertError {
	#[error("Cannot validate origin `{origin}`")]
	ZoneConvert {
		origin: String,
		source: ZoneConvertError,
	},
}

impl TryFrom<Raw> for Config {
	type Error = ConvertError;

	fn try_from(raw_config: Raw) -> std::result::Result<Self, Self::Error> {
		let zones: std::result::Result<HashMap<String, Zone>, Self::Error> = raw_config
			.zones
			.into_iter()
			.map(|(origin, raw_zone)| {
				let origin_copy = origin.clone();
				let zone: Zone =
					raw_zone
						.try_into()
						.map_err(|source| ConvertError::ZoneConvert {
							origin: origin_copy,
							source,
						})?;
				Ok((origin, zone))
			})
			.collect();

		let default_nix_dir: PathBuf = Path::new("/nix").to_path_buf();
		let nix_dir = raw_config.nix_dir.unwrap_or(default_nix_dir);

		let config = Self {
			db: raw_config.db,
			nix_dir,
			reload_program_bin: raw_config.reload_program_bin,
			zones: zones?,
		};
		Ok(config)
	}
}

#[derive(thiserror::Error, Debug, Eq, PartialEq)]
pub enum ZoneConvertError {
	#[error("Included path `{path}` is relative")]
	RelativeIncludePath { path: String },

	#[error("Path {path} is included multiple times in this zone")]
	DuplicateIncludePath { path: String },

	#[error("MNAME `{mname}` is invalid (must end in a dot)")]
	InvalidMname { mname: String },

	#[error("RNAME `{rname}` is invalid (must end in a dot)")]
	InvalidRname { rname: String },
}

impl TryFrom<ZoneRaw> for Zone {
	type Error = ZoneConvertError;

	fn try_from(raw_zone: ZoneRaw) -> std::result::Result<Self, Self::Error> {
		let mut includes_set: HashSet<PathBuf> = HashSet::new();
		for include in &raw_zone.includes {
			if include.is_relative() {
				return Err(ZoneConvertError::RelativeIncludePath {
					path: include.display().to_string(),
				});
			}

			let was_newly_inserted = includes_set.insert(include.clone());
			if !was_newly_inserted {
				return Err(ZoneConvertError::DuplicateIncludePath {
					path: include.display().to_string(),
				});
			}
		}

		if !raw_zone.soa.mname.ends_with('.') {
			return Err(ZoneConvertError::InvalidMname {
				mname: raw_zone.soa.mname,
			});
		}

		if !raw_zone.soa.rname.ends_with('.') {
			return Err(ZoneConvertError::InvalidRname {
				rname: raw_zone.soa.rname,
			});
		}

		let zone = Self {
			dir: raw_zone.dir,
			reload_program_args: raw_zone.reload_program_args,
			ttl: raw_zone.ttl,
			includes: raw_zone.includes,
			includes_set,
			soa: raw_zone.soa,
		};

		Ok(zone)
	}
}

#[cfg(test)]
mod test {
	#[test]
	fn check_from_raw_zone_to_zone() {
		use crate::config::{PathBuf, Soa, Zone, ZoneConvertError, ZoneRaw};

		let soa = Soa {
			ttl: "1d".to_string(),
			mname: "ns1.example.org.".to_string(),
			rname: "john\\.doe.example.org.".to_string(),
			refresh: "1d".to_string(),
			retry: "2h".to_string(),
			expire: "1000h".to_string(),
			minimum: "1h".to_string(),
		};

		let zone_raw_include_relative = ZoneRaw {
			dir: PathBuf::from("/some/dir"),
			reload_program_args: Vec::new(),
			ttl: "1d".to_string(),
			includes: Vec::from([PathBuf::from("path")]),
			soa: soa.clone(),
		};

		assert_eq!(
			zone_raw_include_relative.try_into(),
			Err::<Zone, _>(ZoneConvertError::RelativeIncludePath {
				path: "path".to_string()
			})
		);

		let zone_raw_include_duplicate = ZoneRaw {
			dir: PathBuf::from("/some/dir"),
			reload_program_args: Vec::new(),
			ttl: "1h".to_string(),
			includes: Vec::from([PathBuf::from("/path"), PathBuf::from("/path")]),
			soa,
		};

		assert_eq!(
			zone_raw_include_duplicate.try_into(),
			Err::<Zone, _>(ZoneConvertError::DuplicateIncludePath {
				path: "/path".to_string()
			})
		);
	}
}
