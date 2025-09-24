// SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
// SPDX-License-Identifier: GPL-3.0-only

use color_eyre::{
	Help, SectionExt,
	eyre::{Result, WrapErr, eyre},
};
use log::info;
use std::path::PathBuf;
use std::process::{Command, Stdio};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reloader {
	pub zone_name: String,
	pub bin: PathBuf,
	pub args: Vec<String>,
}

impl Reloader {
	pub fn execute(&self) -> Result<()> {
		info!(
			"Reloading zone {} with command `{} {}`",
			&self.zone_name,
			&self.bin.display(),
			&self.args.join(" ")
		);

		let child = Command::new(&self.bin)
			.args(&self.args)
			.stdin(Stdio::null())
			.stdout(Stdio::piped())
			.stderr(Stdio::piped())
			.spawn()
			.wrap_err("Failed to spawn updater process")?;

		let output = child
			.wait_with_output()
			.wrap_err("Cannot wait for output from updater process")?;

		if !output.status.success() {
			let stdout = String::from_utf8_lossy(&output.stdout);
			let stderr = String::from_utf8_lossy(&output.stderr);
			return Err(eyre!("The reload command exited with non-zero status code"))
				.with_section(move || stdout.trim().to_string().header("Stdout:"))
				.with_section(move || stderr.trim().to_string().header("Stderr:"));
		}

		Ok(())
	}
}
