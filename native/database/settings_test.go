package configdb_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/experimental/libbox"
)

func TestTypedSettingsRoundTrip(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	path := filepath.Join(t.TempDir(), "catalog.db")
	store, err := configdb.Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	original := config.DefaultHiddifyOptions()
	original.MixedPort = 12345
	original.TLSTricks.EnableFragment = true
	version, err := store.SaveTypedSettings(ctx, original)
	if err != nil {
		t.Fatal(err)
	}
	restored := config.DefaultHiddifyOptions()
	ok, err := configdb.ReadSettings(ctx, configdb.SettingsLocation(path, version), restored)
	if !ok || err != nil {
		t.Fatal(ok, err)
	}
	if restored.MixedPort != 12345 || !restored.TLSTricks.EnableFragment || restored.LogLevel != "off" {
		t.Fatal("typed settings changed")
	}
}

func TestSettingsProducedByDart(t *testing.T) {
	path := os.Getenv("PROXYYOU_DATABASE_SETTINGS_FIXTURE")
	if path == "" {
		t.Skip("cross-runtime fixture not requested")
	}
	ctx := libbox.BaseContext(nil)
	store, err := configdb.Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	var version string
	if err = store.DB.QueryRow("SELECT id FROM application_options WHERE representation='semantic' ORDER BY created DESC LIMIT 1").Scan(&version); err != nil {
		t.Fatal(err)
	}
	restored := config.DefaultHiddifyOptions()
	ok, err := configdb.ReadSettings(context.Background(), configdb.SettingsLocation(path, version), restored)
	if !ok || err != nil {
		t.Fatal(ok, err)
	}
	if restored.LogLevel != "off" || restored.MixedPort == 0 || restored.ConnectionTestUrl != "https://www.youtube.com/generate_204" {
		t.Fatalf("Dart/native settings changed: logging=%s port=%d URL=%s", restored.LogLevel, restored.MixedPort, restored.ConnectionTestUrl)
	}
}
