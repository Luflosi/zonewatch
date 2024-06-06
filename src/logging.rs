// SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
// SPDX-License-Identifier: GPL-3.0-only

use env_logger::{fmt::Formatter, Builder, Env};
use log::Record;
use std::fmt::Display;
use std::io;
use std::io::Write;

// Why do I need to copy so much code from env_logger just to add the Thread name to the log output but don't change anything else?
// Maybe I should take a look at the tracing crate instead.

pub fn setup() {
	let env = Env::default().filter_or("RUST_LOG", "zonewatch=info");
	let mut builder = Builder::from_env(env);

	match std::env::var("RUST_LOG_STYLE") {
		Ok(s) if s == "SYSTEMD" => builder.format(|buf, record| {
			let binding = std::thread::current();
			let thread_name = binding.name().unwrap_or("nameless");
			for line in record.args().to_string().lines() {
				writeln!(
					buf,
					"<{}>{}, Thread {}: {}",
					match record.level() {
						log::Level::Error => 3,
						log::Level::Warn => 4,
						log::Level::Info => 6,
						log::Level::Debug | log::Level::Trace => 7,
					},
					record.target(),
					thread_name,
					line
				)?;
			}
			Ok(())
		}),
		_ => builder.format(|buf, record| {
			begin_header(buf)?;
			write_timestamp(buf)?;
			write_level(buf, record)?;
			write_thread_name(buf)?;
			write_target(buf, record)?;
			finish_header(buf)?;

			write_args(buf, record)?;
			writeln!(buf)
		}),
	}
	.init();
}

fn begin_header(buf: &mut Formatter) -> io::Result<()> {
	let open_brace = subtle_style("[");
	write!(buf, "{open_brace}")
}

fn write_timestamp(buf: &mut Formatter) -> io::Result<()> {
	let ts = buf.timestamp_seconds();
	write!(buf, "{ts}")
}

fn write_level(buf: &mut Formatter, record: &Record<'_>) -> io::Result<()> {
	let level = {
		let level = record.level();
		StyledValue {
			style: buf.default_level_style(level),
			value: level,
		}
	};

	write!(buf, " {level:<5}")
}

fn write_thread_name(buf: &mut Formatter) -> io::Result<()> {
	let binding = std::thread::current();
	let thread_name = binding.name().unwrap_or("nameless");
	write!(buf, " Thread {thread_name}")
}

fn write_target(buf: &mut Formatter, record: &Record<'_>) -> io::Result<()> {
	match record.target() {
		"" => Ok(()),
		target => write!(buf, " {target}"),
	}
}

fn finish_header(buf: &mut Formatter) -> io::Result<()> {
	let close_brace = subtle_style("]");
	write!(buf, "{close_brace} ")
}

fn write_args(buf: &mut Formatter, record: &Record<'_>) -> io::Result<()> {
	write!(buf, "{}", record.args())
}

type SubtleStyle = StyledValue<&'static str>;

struct StyledValue<T> {
	style: env_logger::fmt::style::Style,
	value: T,
}

impl<T: Display> Display for StyledValue<T> {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		let style = self.style;

		// We need to make sure `f`s settings don't get passed onto the styling but do get passed
		// to the value
		write!(f, "{style}")?;
		self.value.fmt(f)?;
		write!(f, "{style:#}")?;
		Ok(())
	}
}

const fn subtle_style(text: &'static str) -> SubtleStyle {
	StyledValue {
		style: env_logger::fmt::style::AnsiColor::BrightBlack.on_default(),
		value: text,
	}
}
