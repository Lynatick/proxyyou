package configdb_test

import (
	"github.com/sagernet/sing-box/experimental/libbox"
	"os"
	"testing"
)

func TestMain(m *testing.M) {
	directory, err := os.MkdirTemp("", "proxyyou-db-tests")
	if err != nil {
		panic(err)
	}
	libbox.Setup(&libbox.SetupOptions{BasePath: directory, WorkingPath: directory, TempPath: directory})
	code := m.Run()
	os.RemoveAll(directory)
	os.Exit(code)
}
