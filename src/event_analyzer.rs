// SPDX-FileCopyrightText: 2024 Luflosi <zonewatch@luflosi.de>
// SPDX-License-Identifier: GPL-3.0-only

use log::trace;
use notify::{
	Event, EventKind,
	event::{AccessKind, CreateKind, DataChange, MetadataKind, ModifyKind, RemoveKind, RenameMode},
};
use std::collections::HashSet;
use std::path::PathBuf;

#[derive(Debug, PartialEq, Eq)]
pub enum UncertainModification {
	MaybeModified,
	NotModified,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Changes {
	None,
	Some(HashSet<PathBuf>),
	All,
}

impl Changes {
	pub fn add(self, iter: HashSet<PathBuf>) -> Self {
		match self {
			Self::All => Self::All,
			Self::Some(mut v) => {
				v.extend(iter);
				Self::Some(v)
			}
			Self::None => Self::Some(iter),
		}
	}

	pub fn union(self, new_changes: Self) -> Self {
		match new_changes {
			Self::All => Self::All,
			Self::Some(v) => self.add(v),
			Self::None => self,
		}
	}
}

fn check_paths(
	zone_name: &str,
	zone_paths: &HashSet<PathBuf>,
	event_paths: Vec<PathBuf>,
) -> Changes {
	let event_paths: HashSet<PathBuf> = event_paths.into_iter().collect();
	let intersection = zone_paths.intersection(&event_paths);
	let intersection_set: HashSet<PathBuf> = intersection.cloned().collect();
	let count = intersection_set.len();
	if count == 0 {
		trace!("None of the files we're interested in were changed (zone {zone_name})");
		return Changes::None;
	}
	trace!("{count} file(s) we're interested in were changed (zone {zone_name})");
	Changes::Some(intersection_set)
}

pub fn analyze_event(zone_name: &str, zone_paths: &HashSet<PathBuf>, event: Event) -> Changes {
	use UncertainModification::{MaybeModified, NotModified};

	trace!(
		"Zone: {zone_name}, Event kind: {:?}, Event paths: {:?}, Event Attrs: {:?}",
		event.kind, event.paths, event.attrs
	);
	if event.need_rescan() {
		// Some events may have been missed.
		// We need to read all files again to be sure.
		return Changes::All;
	}
	// These match statements could be simplified by using `_`
	// but I like to list most of the cases individually,
	// so I can reason about them individually and won't forget any cases
	let uncertain_modified_state = match event.kind {
		EventKind::Any | EventKind::Other => MaybeModified,
		EventKind::Access(v) => match v {
			AccessKind::Any
			| AccessKind::Read
			| AccessKind::Other
			| AccessKind::Open(_)
			| AccessKind::Close(_) => NotModified,
		},
		EventKind::Create(v) => match v {
			CreateKind::Any | CreateKind::File | CreateKind::Other => MaybeModified,
			CreateKind::Folder => NotModified,
		},
		EventKind::Modify(v) => match v {
			ModifyKind::Any | ModifyKind::Other => MaybeModified,
			ModifyKind::Data(v) => match v {
				DataChange::Any | DataChange::Size | DataChange::Content | DataChange::Other => {
					MaybeModified
				}
			},
			ModifyKind::Metadata(v) => match v {
				MetadataKind::Any
				| MetadataKind::AccessTime
				| MetadataKind::WriteTime
				| MetadataKind::Extended
				| MetadataKind::Other => NotModified,
				// Let's check if we can still read the file
				MetadataKind::Permissions | MetadataKind::Ownership => MaybeModified,
			},
			ModifyKind::Name(v) => match v {
				RenameMode::Any
				| RenameMode::To
				| RenameMode::From
				| RenameMode::Both
				| RenameMode::Other => MaybeModified,
			},
		},
		EventKind::Remove(v) => match v {
			RemoveKind::Any | RemoveKind::File | RemoveKind::Other => MaybeModified,
			RemoveKind::Folder => NotModified,
		},
	};

	match uncertain_modified_state {
		MaybeModified => {
			trace!("Checking if it's a file we are interested in (zone {zone_name})");
			check_paths(zone_name, zone_paths, event.paths)
		}
		NotModified => Changes::None,
	}
}

#[cfg(test)]
mod test {
	use crate::event_analyzer::{
		Changes::{None, Some},
		HashSet, PathBuf,
	};

	const fn init() {
		/*
		use env_logger::Env;

		let env = Env::default().default_filter_or("trace");
		let _ = env_logger::Builder::from_env(env).is_test(true).try_init();
		*/
	}

	#[test]
	fn check_paths_test() {
		use crate::event_analyzer::check_paths;

		init();

		let zone_name = "test";
		let path1 = PathBuf::from("/path1");
		let path2 = PathBuf::from("/path/2");
		let path3 = PathBuf::from("path-3");
		let zone_paths_all = HashSet::from([path1.clone(), path2.clone(), path3.clone()]);
		let event_paths_all = Vec::from([path1, path2.clone(), path3]);
		let zone_paths_one = HashSet::from([path2.clone()]);
		let event_paths_one = Vec::from([path2]);
		let zone_paths_empty = HashSet::new();
		let event_paths_empty = Vec::new();
		assert_eq!(
			check_paths(zone_name, &zone_paths_all, event_paths_all.clone()),
			Some(zone_paths_all.clone())
		);
		assert_eq!(
			check_paths(zone_name, &zone_paths_all, event_paths_one.clone()),
			Some(zone_paths_one.clone())
		);
		assert_eq!(
			check_paths(zone_name, &zone_paths_all, event_paths_empty.clone()),
			None
		);
		assert_eq!(
			check_paths(zone_name, &zone_paths_one, event_paths_all.clone()),
			Some(zone_paths_one.clone())
		);
		assert_eq!(
			check_paths(zone_name, &zone_paths_one, event_paths_one.clone()),
			Some(zone_paths_one.clone())
		);
		assert_eq!(
			check_paths(zone_name, &zone_paths_one, event_paths_empty.clone()),
			None
		);
		assert_eq!(
			check_paths(zone_name, &zone_paths_empty, event_paths_all),
			None
		);
		assert_eq!(
			check_paths(zone_name, &zone_paths_empty, event_paths_one),
			None
		);
		assert_eq!(
			check_paths(zone_name, &zone_paths_empty, event_paths_empty),
			None
		);
	}

	#[test]
	fn process_event_test() {
		use crate::event_analyzer::analyze_event;
		use notify::{
			Event, EventKind,
			EventKind::{Access, Any, Create, Modify, Other, Remove},
			event::{
				AccessKind, AccessMode, CreateKind, DataChange, MetadataKind, ModifyKind,
				RemoveKind, RenameMode,
			},
		};

		fn assert_modified(event_kind: EventKind, expect_modified: bool) {
			let zone_name = "test";
			let path = PathBuf::from("/path");
			let zone_paths = HashSet::from([path.clone()]);
			let event = Event::new(event_kind).add_path(path);
			let expected_state = if expect_modified {
				Some(zone_paths.clone())
			} else {
				None
			};
			assert_eq!(analyze_event(zone_name, &zone_paths, event), expected_state);
		}

		init();

		assert_modified(Any, true);
		assert_modified(Access(AccessKind::Any), false);
		assert_modified(Access(AccessKind::Read), false);
		assert_modified(Access(AccessKind::Open(AccessMode::Any)), false);
		assert_modified(Access(AccessKind::Close(AccessMode::Any)), false);
		assert_modified(Access(AccessKind::Other), false);
		assert_modified(Create(CreateKind::Any), true);
		assert_modified(Create(CreateKind::File), true);
		assert_modified(Create(CreateKind::Folder), false);
		assert_modified(Create(CreateKind::Other), true);
		assert_modified(Modify(ModifyKind::Any), true);
		assert_modified(Modify(ModifyKind::Data(DataChange::Any)), true);
		assert_modified(Modify(ModifyKind::Data(DataChange::Size)), true);
		assert_modified(Modify(ModifyKind::Data(DataChange::Content)), true);
		assert_modified(Modify(ModifyKind::Data(DataChange::Other)), true);
		assert_modified(Modify(ModifyKind::Metadata(MetadataKind::Any)), false);
		assert_modified(
			Modify(ModifyKind::Metadata(MetadataKind::AccessTime)),
			false,
		);
		assert_modified(Modify(ModifyKind::Metadata(MetadataKind::WriteTime)), false);
		assert_modified(
			Modify(ModifyKind::Metadata(MetadataKind::Permissions)),
			true,
		);
		assert_modified(Modify(ModifyKind::Metadata(MetadataKind::Ownership)), true);
		assert_modified(Modify(ModifyKind::Metadata(MetadataKind::Extended)), false);
		assert_modified(Modify(ModifyKind::Metadata(MetadataKind::Other)), false);
		assert_modified(Modify(ModifyKind::Name(RenameMode::Any)), true);
		assert_modified(Modify(ModifyKind::Name(RenameMode::To)), true);
		assert_modified(Modify(ModifyKind::Name(RenameMode::From)), true);
		assert_modified(Modify(ModifyKind::Name(RenameMode::Both)), true);
		assert_modified(Modify(ModifyKind::Name(RenameMode::Other)), true);
		assert_modified(Modify(ModifyKind::Other), true);
		assert_modified(Remove(RemoveKind::Any), true);
		assert_modified(Remove(RemoveKind::File), true);
		assert_modified(Remove(RemoveKind::Folder), false);
		assert_modified(Remove(RemoveKind::Other), true);
		assert_modified(Other, true);
	}
}
