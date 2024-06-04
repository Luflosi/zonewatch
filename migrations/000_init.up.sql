CREATE TABLE IF NOT EXISTS zones (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL UNIQUE,
	dir TEXT NOT NULL,
	ttl TEXT NOT NULL,
	soa_ttl TEXT NOT NULL,
	soa_mname TEXT NOT NULL,
	soa_rname TEXT NOT NULL,
	soa_serial INTEGER NOT NULL,
	soa_refresh TEXT NOT NULL,
	soa_retry TEXT NOT NULL,
	soa_expire TEXT NOT NULL,
	soa_minimum TEXT NOT NULL
) STRICT;
CREATE INDEX zones_index ON zones(name);

CREATE TABLE IF NOT EXISTS includes (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	zoneid INTEGER NOT NULL,
	path TEXT NOT NULL,
	hash BLOB,
	error INTEGER,
	FOREIGN KEY(zoneid) REFERENCES zones(id),
	UNIQUE (zoneid, path),
	CHECK ((hash IS NULL) <> (error IS NULL))
) STRICT;
CREATE INDEX includes_index ON includes(zoneid, path);
