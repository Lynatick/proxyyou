package configdb_test

import (
	"github.com/hiddify/hiddify-core/v2/configdb"
	"path/filepath"
	"testing"
)

func TestDartWindowsURIIsAUsableNativePath(t *testing.T) {
	location, ok, err := configdb.ParseLocation("proxyyou-db:/C:/Users/test/My%20Dir/configurations.db?profile=p")
	if !ok || err != nil {
		t.Fatal(ok, err)
	}
	if location.Path != filepath.FromSlash("C:/Users/test/My Dir/configurations.db") {
		t.Fatal("drive prefix changed", location.Path)
	}
	roundtrip, ok, err := configdb.ParseLocation(location.String())
	if !ok || err != nil || roundtrip != location {
		t.Fatal("URI changed", roundtrip, err)
	}
}
