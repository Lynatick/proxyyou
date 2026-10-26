package configdb_test

import (
	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/option"
	"path/filepath"
	"testing"
)

func TestDeletingProfileKeepsPinnedRevisionReadableUntilRelease(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	store, err := configdb.Open(ctx, filepath.Join(t.TempDir(), "catalog.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	options := &option.Options{Outbounds: []option.Outbound{{Type: "socks", Tag: "server", Options: &option.SOCKSOutboundOptions{ServerOptions: option.ServerOptions{Server: "127.0.0.1", ServerPort: 9001}}}}}
	revision, err := store.Import(ctx, "profile", options, map[string]configdb.Descriptor{"server": {Network: []string{"tcp"}}}, "hash")
	if err != nil {
		t.Fatal(err)
	}
	_, token, err := store.Pin(ctx, configdb.Location{Profile: "profile"})
	if err != nil {
		t.Fatal(err)
	}
	if err = store.DeleteProfile(ctx, "profile"); err != nil {
		t.Fatal(err)
	}
	if _, err = store.Resolve(ctx, "profile", ""); err == nil {
		t.Fatal("deleted profile remains active")
	}
	entries, err := store.Entries(ctx, revision)
	if err != nil || len(entries) != 1 {
		t.Fatal("pinned catalogue disappeared", err)
	}
	if _, err = store.ReadOptions(ctx, revision, entries[0]); err != nil {
		t.Fatal(err)
	}
	store.Unpin(token)
	var count int
	if err = store.DB.QueryRow("SELECT count(*) FROM subscription_revisions WHERE profile_id='profile'").Scan(&count); err != nil || count != 0 {
		t.Fatal("retired catalogue leaked", count, err)
	}
}

func TestDeletedSourceCannotReactivateOrRecreateSelection(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	path := filepath.Join(t.TempDir(), "catalog.db")
	store, err := configdb.Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	options := &option.Options{Outbounds: []option.Outbound{{Type: "socks", Tag: "server", Options: &option.SOCKSOutboundOptions{ServerOptions: option.ServerOptions{Server: "127.0.0.1", ServerPort: 9001}}}}}
	if _, err = store.Import(ctx, "profile", options, map[string]configdb.Descriptor{"server": {Network: []string{"tcp"}}}, "hash"); err != nil {
		t.Fatal(err)
	}
	loaded, err := configdb.Load(ctx, configdb.Location{Path: path, Profile: "profile"})
	if err != nil {
		t.Fatal(err)
	}
	defer loaded.DatabaseSource.Close()
	if err = store.DeleteProfile(ctx, "profile"); err != nil {
		t.Fatal(err)
	}
	if err = loaded.DatabaseSource.Activate(); err == nil {
		t.Fatal("deleted source was reactivated")
	}
	if err = loaded.DatabaseSource.StoreSelection("select", "server"); err == nil {
		t.Fatal("deleted selection was recreated")
	}
}

func TestProfileInUseCannotBeDeletedUntilConfirmedStop(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	path := filepath.Join(t.TempDir(), "catalog.db")
	store, err := configdb.Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	options := &option.Options{Outbounds: []option.Outbound{{Type: "socks", Tag: "server", Options: &option.SOCKSOutboundOptions{ServerOptions: option.ServerOptions{Server: "127.0.0.1", ServerPort: 9001}}}}}
	if _, err = store.Import(ctx, "profile", options, map[string]configdb.Descriptor{"server": {Network: []string{"tcp"}}}, "hash"); err != nil {
		t.Fatal(err)
	}
	loaded, err := configdb.Load(ctx, configdb.Location{Path: path, Profile: "profile"})
	if err != nil {
		t.Fatal(err)
	}
	if err = loaded.DatabaseSource.Activate(); err != nil {
		t.Fatal(err)
	}
	if err = store.DeleteProfile(ctx, "profile"); err == nil {
		t.Fatal("working profile deleted")
	}
	if _, err = store.Resolve(ctx, "profile", ""); err != nil {
		t.Fatal("rejected deletion lost active revision", err)
	}
	loaded.DatabaseSource.Close()
	if err = store.DeleteProfile(ctx, "profile"); err != nil {
		t.Fatal("stopped profile not deleted", err)
	}
}
