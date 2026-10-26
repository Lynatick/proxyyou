package hcore

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
)

func TestLoggingDisabledByDefault(t *testing.T) {
	directory := t.TempDir()
	libbox.Setup(&libbox.SetupOptions{BasePath: directory, WorkingPath: directory, TempPath: directory})
	input := &option.Options{Outbounds: []option.Outbound{{Type: "socks", Tag: "test", Options: &option.SOCKSOutboundOptions{ServerOptions: option.ServerOptions{Server: "127.0.0.1", ServerPort: 9001}}}}}
	options, err := config.BuildConfig(libbox.BaseContext(nil), config.DefaultHiddifyOptions(), &config.ReadOptions{Options: input})
	if err != nil {
		t.Fatal(err)
	}
	if options.Log == nil || !options.Log.Disabled {
		t.Fatal("native logging enabled by default")
	}
	defaults := config.DefaultHiddifyOptions()
	if defaults.LogLevel != "off" {
		t.Fatal("default core log level", defaults.LogLevel)
	}
	factory, err := log.New(log.Options{Context: context.Background(), Options: option.LogOptions{Disabled: true, Level: defaults.LogLevel, Output: filepath.Join(directory, "box.log")}})
	if err != nil {
		t.Fatal(err)
	}
	if err = factory.Start(); err != nil {
		t.Fatal(err)
	}
	factory.Logger().Error("disabled diagnostic")
	factory.Close()
	if _, err = os.Stat(filepath.Join(directory, "box.log")); !os.IsNotExist(err) {
		t.Fatal("disabled logger created a file", err)
	}
}

func TestGlobalCoreLoggingFollowsExplicitOptIn(t *testing.T) {
	directory := t.TempDir()
	libbox.Setup(&libbox.SetupOptions{BasePath: directory, WorkingPath: directory, TempPath: directory})
	previousLogger := log.StdLogger()
	previousFactory := static.CoreLogFactory
	previousOptions := static.HiddifyOptions
	previousEnabled := loggingEnabled.Load()
	previousLevel := static.logLevel.Load()
	previousDebug := static.debug.Load()
	defer func() {
		log.SetStdLogger(previousLogger)
		static.CoreLogFactory = previousFactory
		static.HiddifyOptions = previousOptions
		loggingEnabled.Store(previousEnabled)
		static.logLevel.Store(previousLevel)
		static.debug.Store(previousDebug)
	}()
	var output bytes.Buffer
	factory, err := log.New(log.Options{Context: context.Background(), DefaultWriter: &output})
	if err != nil {
		t.Fatal(err)
	}
	defer factory.Close()
	static.CoreLogFactory = factory
	log.SetStdLogger(factory.Logger())
	log.Info("before disabling")
	before := output.Len()
	if _, err = ChangeHiddifySettings(&ChangeHiddifySettingsRequest{}, false); err != nil {
		t.Fatal(err)
	}
	log.Info("must be suppressed")
	if output.Len() != before {
		t.Fatal("global logger bypassed disabled preference")
	}
	ctx := libbox.BaseContext(nil)
	path := filepath.Join(t.TempDir(), "catalog.db")
	store, err := configdb.Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	settings := config.DefaultHiddifyOptions()
	settings.LogLevel = "debug"
	version, err := store.SaveTypedSettings(ctx, settings)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = ChangeHiddifySettings(&ChangeHiddifySettingsRequest{HiddifySettingsJson: configdb.SettingsLocation(path, version)}, false); err != nil {
		t.Fatal(err)
	}
	log.Info("manual diagnostic")
	if !strings.Contains(output.String(), "manual diagnostic") {
		t.Fatal("manual global logging could not be enabled")
	}
}
