package hcore

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/option"
)

func TestDatabaseImportAndBuildWithoutJSONFiles(t *testing.T) {
	directory := t.TempDir()
	libbox.Setup(&libbox.SetupOptions{BasePath: directory, WorkingPath: directory, TempPath: directory})
	ctx := libbox.FromContext(context.Background(), nil)
	previous := static.HiddifyOptions
	static.HiddifyOptions = config.DefaultHiddifyOptions()
	defer func() { static.HiddifyOptions = previous }()
	location := configdb.Location{Path: filepath.Join(directory, "catalog.db"), Profile: "test-profile"}
	content := `{"outbounds":[{"type":"socks","tag":"server-a","server":"127.0.0.1","server_port":9001},{"type":"socks","tag":"server-b","server":"127.0.0.1","server_port":9002}]}`
	response, err := Parse(ctx, &ParseRequest{ConfigPath: location.String(), Content: content})
	if err != nil {
		t.Fatal(err)
	}
	if response.Content != "" {
		t.Fatal("database importer returned a serialized JSON document")
	}
	options, err := BuildConfig(ctx, &StartRequest{ConfigPath: location.String()})
	if err != nil {
		t.Fatal(err)
	}
	if options.DatabaseSource == nil {
		t.Fatal("database source not propagated")
	}
	defer options.DatabaseSource.Close()
	found := map[string]bool{}
	for _, out := range options.Outbounds {
		if out.Tag == "server-a" {
			deferred, ok := out.Options.(*option.DeferredOutboundOptions)
			if !ok {
				t.Fatal("server eagerly loaded")
			}
			loaded, loadErr := deferred.Load(ctx)
			if loadErr != nil {
				t.Fatal(loadErr)
			}
			if loaded.(*option.SOCKSOutboundOptions).ServerPort != 9001 {
				t.Fatal("wrong parameters from table")
			}
		}
		found[out.Tag] = true
	}
	for _, tag := range []string{"server-a", "server-b", "balance", "lowest", "select"} {
		if !found[tag] {
			t.Fatal("missing database-backed outbound", tag)
		}
	}
	source := options.DatabaseSource
	options.DatabaseSource = nil
	if err = libbox.CheckConfigOptions(options); err != nil {
		t.Fatal(err)
	}
	options.DatabaseSource = source
	if err = filepath.WalkDir(directory, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if filepath.Ext(path) == ".json" {
			t.Errorf("unexpected intermediate JSON file: %s", path)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}
