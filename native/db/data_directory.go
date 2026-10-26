package db

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync/atomic"
)

type storageDirectories struct {
	current string
	legacy  string
}

var directories atomic.Pointer[storageDirectories]

// ConfigureDataDirectory keeps service bookkeeping on a filesystem supporting
// LevelDB's flock locks. Android external emulated storage may return ENOSYS.
// Configuration catalogs retain their existing paths; only legacy native tables
// move. Each old table is copied before an atomic directory rename publishes it.
func ConfigureDataDirectory(current, legacy string) error {
	current, err := filepath.Abs(current)
	if err != nil {
		return err
	}
	legacy, err = filepath.Abs(legacy)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(current, 0700); err != nil {
		return err
	}
	directories.Store(&storageDirectories{current: current, legacy: legacy})
	return nil
}

func databaseDirectory(name string) (string, error) {
	configured := directories.Load()
	if configured == nil {
		return "./data", nil
	}
	if configured.current == configured.legacy {
		return configured.current, nil
	}
	target := filepath.Join(configured.current, name+".db")
	if info, err := os.Lstat(target); err == nil {
		if !info.IsDir() {
			return "", fmt.Errorf("service database is not a directory: %s", target)
		}
		return configured.current, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	previous := filepath.Join(configured.legacy, name+".db")
	info, err := os.Lstat(previous)
	if errors.Is(err, os.ErrNotExist) {
		return configured.current, nil
	}
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", fmt.Errorf("legacy service database is not a directory: %s", previous)
	}
	stage, err := os.MkdirTemp(configured.current, ".migrate-"+name+"-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stage)
	if err = copyDatabaseDirectory(previous, stage); err != nil {
		return "", err
	}
	if err = os.Rename(stage, target); err != nil {
		// Another process may have published the same complete migration first.
		if published, inspectErr := os.Lstat(target); inspectErr != nil || !published.IsDir() {
			return "", err
		}
	}
	return configured.current, nil
}

func copyDatabaseDirectory(source, target string) error {
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		from, to := filepath.Join(source, entry.Name()), filepath.Join(target, entry.Name())
		if entry.IsDir() {
			if err = os.Mkdir(to, 0700); err == nil {
				err = copyDatabaseDirectory(from, to)
			}
		} else if entry.Type().IsRegular() {
			err = copyDatabaseFile(from, to)
		} else {
			err = fmt.Errorf("unsupported entry in legacy service database: %s", from)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func copyDatabaseFile(source, target string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = io.Copy(output, input)
	if err == nil {
		err = output.Sync()
	}
	closeErr := output.Close()
	if err != nil {
		return err
	}
	return closeErr
}
