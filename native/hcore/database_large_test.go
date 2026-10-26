package hcore

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/option"
)

func TestDatabaseLargeSubscription(t *testing.T) {
	input := os.Getenv("PROXYYOU_DATABASE_IMPORT_FIXTURE")
	if input == "" {
		t.Skip("large external import fixture not requested")
	}
	directory := t.TempDir()
	libbox.Setup(&libbox.SetupOptions{BasePath: directory, WorkingPath: directory, TempPath: directory})
	previous := static.HiddifyOptions
	static.HiddifyOptions = config.DefaultHiddifyOptions()
	defer func() { static.HiddifyOptions = previous }()
	ctx := libbox.FromContext(context.Background(), nil)
	location := configdb.Location{Path: filepath.Join(directory, "catalog.db"), Profile: "large"}
	started := time.Now()
	response, err := Parse(ctx, &ParseRequest{ConfigPath: location.String(), TempPath: input})
	if err != nil {
		t.Fatal(err)
	}
	imported := time.Since(started)
	if response.Content != "" {
		t.Fatal("import returned an intermediate JSON document")
	}
	started = time.Now()
	options, err := BuildConfig(ctx, &StartRequest{ConfigPath: location.String()})
	if err != nil {
		t.Fatal(err)
	}
	defer options.DatabaseSource.Close()
	references := 0
	for _, out := range options.Outbounds {
		if _, ok := out.Options.(*option.DeferredOutboundOptions); ok {
			references++
		}
	}
	if references < 30000 {
		t.Fatal("large catalogue unexpectedly truncated", references)
	}
	if err = filepath.WalkDir(directory, func(path string, entry os.DirEntry, err error) error {
		if err == nil && filepath.Ext(path) == ".json" {
			t.Errorf("intermediate JSON file: %s", path)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	var memory runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&memory)
	t.Logf("configurations=%d import=%s typed_source_load=%s heap_mib=%.1f", references, imported, time.Since(started), float64(memory.HeapAlloc)/(1<<20))
}
