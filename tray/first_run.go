package main

import (
	"os"
	"path/filepath"
)

// IsFirstRun returns true when the Scry2 database does not yet exist.
//
// "First run" means: the user has never successfully launched this app on
// this machine with this data directory. The database file is created by
// the backend on first boot (via Ecto.Migrator), so its absence is a
// reliable signal that the tray has not yet reached a working state.
//
// On reinstall that preserves the data dir, this returns false — the user
// already knows where the dashboard lives and does not need another browser
// window popped in their face. On manual deletion of the data dir or a
// genuinely fresh install, it returns true.
func IsFirstRun() bool {
	dbPath := filepath.Join(DataDir(), "scry_2.db")
	_, err := os.Stat(dbPath)
	return os.IsNotExist(err)
}
