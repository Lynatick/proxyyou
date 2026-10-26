package configdb_test

import (
	"context"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

func TestRelationalCodecPreservesTypesWithoutJSON(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	codec := configdb.ContextCodec(ctx)
	original := option.Options{Outbounds: []option.Outbound{{Type: "vless", Tag: "one", Options: &option.VLESSOutboundOptions{
		ServerOptions: option.ServerOptions{Server: "example.invalid", ServerPort: 443}, UUID: "00000000-0000-0000-0000-000000000001",
		OutboundTLSOptionsContainer: option.OutboundTLSOptionsContainer{TLS: &option.OutboundTLSOptions{Enabled: true, ALPN: []string{"h2", "http/1.1"}, Reality: &option.OutboundRealityOptions{Enabled: true, PublicKey: "key", ShortID: "abc"}}},
	}}}}
	fields, err := codec.Encode(original)
	if err != nil {
		t.Fatal(err)
	}
	var restored option.Options
	if err = codec.Decode(fields, &restored); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(original, restored) {
		t.Fatalf("typed configuration did not roundtrip")
	}
	if len(fields) < 10 {
		t.Fatal("expected relational parameter rows")
	}
	for _, field := range fields {
		if field.Kind == "json" {
			t.Fatal("JSON in relational representation")
		}
	}
}

func TestRelationalCodecPreservesPrefixAndGenericMaps(t *testing.T) {
	type values struct {
		Prefix   badoption.Prefixable
		Address  badoption.Addr
		Data     map[string]any
		Empty    []string
		Optional *bool
	}
	flag := false
	original := values{Prefix: badoption.Prefixable(netip.MustParsePrefix("2001:db8::/32")), Address: badoption.Addr(netip.MustParseAddr("::1")), Data: map[string]any{"enabled": true, "items": []any{"name", float64(9), nil}}, Empty: []string{}, Optional: &flag}
	codec := configdb.NewCodec(original)
	fields, err := codec.Encode(original)
	if err != nil {
		t.Fatal(err)
	}
	var restored values
	if err = codec.Decode(fields, &restored); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(original, restored) {
		t.Fatal("relational special values changed")
	}
}

func TestInterruptedImportPreservesActiveRevision(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	store, err := configdb.Open(ctx, filepath.Join(t.TempDir(), "configurations.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	original := &option.Options{Outbounds: []option.Outbound{{Type: "socks", Tag: "server", Options: &option.SOCKSOutboundOptions{ServerOptions: option.ServerOptions{Server: "127.0.0.1", ServerPort: 9001}}}}}
	descriptors := map[string]configdb.Descriptor{"server": {Network: []string{"tcp", "udp"}, Display: "SOCKS"}}
	first, err := store.Import(ctx, "profile", original, descriptors, "source-v1")
	if err != nil {
		t.Fatal(err)
	}
	options := original.Outbounds[0].Options.(*option.SOCKSOutboundOptions)
	options.ServerPort = 9002
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err = store.Import(canceled, "profile", original, descriptors, "source-v2"); err == nil {
		t.Fatal("canceled import succeeded")
	}
	active, err := store.Resolve(ctx, "profile", "")
	if err != nil || active != first {
		t.Fatal("active revision lost", err)
	}
	entries, err := store.Entries(ctx, first)
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := store.ReadOptions(ctx, first, entries[0])
	if err != nil {
		t.Fatal(err)
	}
	if loaded.(*option.SOCKSOutboundOptions).ServerPort != 9001 {
		t.Fatal("previous revision mutated")
	}
	second, err := store.Import(ctx, "profile", original, descriptors, "source-v2")
	if err != nil {
		t.Fatal(err)
	}
	if second == first {
		t.Fatal("revision identity reused")
	}
	var count int
	if err = store.DB.QueryRow("SELECT count(*) FROM configuration_entries WHERE revision=? AND section='outbounds'", second).Scan(&count); err != nil || count != 1 {
		t.Fatal("configuration count", count, err)
	}
}

func TestInvalidConfigurationKeepsDiagnosticWithoutSerializedErrorObject(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	codec := configdb.ContextCodec(ctx)
	original := option.HInvalidOptions{Err: fmt.Errorf("bad server address"), InvalidConfig: map[string]any{"server": "invalid", "enabled": false}}
	fields, err := codec.Encode(original)
	if err != nil {
		t.Fatal(err)
	}
	var restored option.HInvalidOptions
	if err = codec.Decode(fields, &restored); err != nil {
		t.Fatal(err)
	}
	if restored.Err == nil || restored.Err.Error() != original.Err.Error() {
		t.Fatal("diagnostic lost")
	}
	if !reflect.DeepEqual(restored.InvalidConfig, original.InvalidConfig) {
		t.Fatal("invalid configuration fields changed")
	}
}

func TestAbandonedStagingIsReclaimedWithoutTouchingLiveImporter(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	path := filepath.Join(t.TempDir(), "catalog.db")
	store, err := configdb.Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct {
		id  string
		pid int
	}{{"dead", 2147483646}, {"live", os.Getpid()}} {
		if _, err = store.DB.Exec("INSERT INTO subscription_revisions VALUES(?,'profile','staging',1,0,'hash')", item.id); err != nil {
			t.Fatal(err)
		}
		if _, err = store.DB.Exec("INSERT INTO configuration_imports VALUES(?,?)", item.id, item.pid); err != nil {
			t.Fatal(err)
		}
	}
	store.Close()
	store, err = configdb.Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	var count int
	if err = store.DB.QueryRow("SELECT count(*) FROM subscription_revisions WHERE id='dead'").Scan(&count); err != nil || count != 0 {
		t.Fatal("dead import remains", count, err)
	}
	if err = store.DB.QueryRow("SELECT count(*) FROM subscription_revisions WHERE id='live'").Scan(&count); err != nil || count != 1 {
		t.Fatal("live import reclaimed", count, err)
	}
}
