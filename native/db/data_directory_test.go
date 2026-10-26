package db

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/hiddify/hiddify-core/v2/hcommon"
)

func TestPrivateServiceDirectoryMigratesValuesAndKeepsOriginal(t *testing.T) {
	previous := directories.Load()
	t.Cleanup(func() { directories.Store(previous) })
	legacy, private := t.TempDir(), t.TempDir()
	if err := ConfigureDataDirectory(legacy, legacy); err != nil {
		t.Fatal(err)
	}
	table := GetTable[hcommon.AppSettings]()
	if err := table.UpdateInsert(&hcommon.AppSettings{Id: "settings", Value: "proxyyou-settings:/existing"}); err != nil {
		t.Fatal(err)
	}
	if err := ConfigureDataDirectory(private, legacy); err != nil {
		t.Fatal(err)
	}
	value, err := table.Get("settings")
	if err != nil || value.Value != "proxyyou-settings:/existing" {
		t.Fatalf("migrated value: %v, %v", value, err)
	}
	if err = table.UpdateInsert(&hcommon.AppSettings{Id: "settings", Value: "proxyyou-settings:/updated"}); err != nil {
		t.Fatal(err)
	}
	if err = ConfigureDataDirectory(legacy, legacy); err != nil {
		t.Fatal(err)
	}
	value, err = table.Get("settings")
	if err != nil || value.Value != "proxyyou-settings:/existing" {
		t.Fatalf("original was changed: %v, %v", value, err)
	}
	if err = ConfigureDataDirectory(private, legacy); err != nil {
		t.Fatal(err)
	}
	value, err = table.Get("settings")
	if err != nil || value.Value != "proxyyou-settings:/updated" {
		t.Fatalf("second migration overwrote private values: %v, %v", value, err)
	}
}

func TestFailedServiceMigrationDoesNotPublishPartialTable(t *testing.T) {
	previous := directories.Load()
	t.Cleanup(func() { directories.Store(previous) })
	legacy, private := t.TempDir(), t.TempDir()
	old := filepath.Join(legacy, "AppSettings.db")
	if err := os.Mkdir(old, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("missing", filepath.Join(old, "CURRENT")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := ConfigureDataDirectory(private, legacy); err != nil {
		t.Fatal(err)
	}
	if _, err := databaseDirectory("AppSettings"); err == nil {
		t.Fatal("unsupported entry was accepted")
	}
	if _, err := os.Stat(filepath.Join(private, "AppSettings.db")); !os.IsNotExist(err) {
		t.Fatalf("partial migration published: %v", err)
	}
}

func TestPrivateServiceStorageInitializesAbandonedLegacyTable(t *testing.T) {
	previous := directories.Load()
	t.Cleanup(func() { directories.Store(previous) })
	legacy, private := t.TempDir(), t.TempDir()
	old := filepath.Join(legacy, "AppSettings.db")
	if err := os.Mkdir(old, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(old, "LOCK"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := ConfigureDataDirectory(private, legacy); err != nil {
		t.Fatal(err)
	}
	table := GetTable[hcommon.AppSettings]()
	if err := table.UpdateInsert(&hcommon.AppSettings{Id: "settings", Value: "new settings"}); err != nil {
		t.Fatal(err)
	}
	value, err := table.Get("settings")
	if err != nil || value.Value != "new settings" {
		t.Fatalf("new value: %v, %v", value, err)
	}
}
