package configdb_test

import (
	"os"
	"reflect"
	"testing"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/experimental/libbox"
)

// Validate parameter preservation against the complete external subscription,
// not just a hand-picked protocol. The fixture remains an import boundary.
func TestEveryFixtureConfigurationPreservesTypedParameters(t *testing.T) {
	path := os.Getenv("PROXYYOU_DATABASE_IMPORT_FIXTURE")
	if path == "" {
		t.Skip("external import fixture not requested")
	}
	ctx := libbox.BaseContext(nil)
	options, err := config.ParseConfig(ctx, &config.ReadOptions{Path: path}, false, config.DefaultHiddifyOptions(), false)
	if err != nil {
		t.Fatal(err)
	}
	codec := configdb.ContextCodec(ctx)
	counts := make(map[string]int)
	verify := func(kind string, value any) {
		t.Helper()
		if value == nil {
			return
		}
		original := reflect.ValueOf(value)
		var target reflect.Value
		if original.Kind() == reflect.Pointer {
			target = reflect.New(original.Type().Elem())
		} else {
			target = reflect.New(original.Type())
		}
		fields, encodeErr := codec.Encode(value)
		if encodeErr != nil {
			t.Fatalf("%s encode: %v", kind, encodeErr)
		}
		if decodeErr := codec.Decode(fields, target.Interface()); decodeErr != nil {
			t.Fatalf("%s decode: %v", kind, decodeErr)
		}
		restored := target.Interface()
		if original.Kind() != reflect.Pointer {
			restored = target.Elem().Interface()
		}
		if !reflect.DeepEqual(value, restored) {
			t.Fatalf("%s parameters changed on relational roundtrip", kind)
		}
		counts[kind]++
	}
	for _, out := range options.Outbounds {
		verify(out.Type, out.Options)
	}
	for _, out := range options.Endpoints {
		verify(out.Type, out.Options)
	}
	t.Logf("roundtripped protocols and configurations: %v", counts)
}
