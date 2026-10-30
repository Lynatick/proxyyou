package hcore

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
 "github.com/sagernet/sing-box/common/interrupt"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/protocol/group"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

func TestVerificationFailureSwitchesAllModesWithoutClosingExistingTCP(t *testing.T) {
	directory := t.TempDir()
	t.Chdir(directory)
	os.MkdirAll("data", 0700)
	if err := libbox.Setup(&libbox.SetupOptions{BasePath: directory, WorkingPath: directory, TempPath: directory}); err != nil {
		t.Fatal(err)
	}
	cert, pool := databaseTestCertificate(t)
	a, stopA := databaseTestSOCKS(t, 'A', cert)
	defer stopA()
	b, stopB := databaseTestSOCKS(t, 'B', cert)
	defer stopB()
	ctx := service.ContextWith[adapter.CertificateStore](libbox.FromContext(context.Background(), nil), &databaseTestTrust{pool: pool})
	oldOpt, oldSvc, oldState := static.HiddifyOptions, static.StartedService, static.CoreState
	defer func() { static.HiddifyOptions = oldOpt; static.StartedService = oldSvc; static.CoreState = oldState }()
	static.HiddifyOptions = config.DefaultHiddifyOptions()
	static.HiddifyOptions.MixedPort = 0
	static.HiddifyOptions.DirectPort = 0
	static.HiddifyOptions.RedirectPort = 0
	static.HiddifyOptions.TProxyPort = 0
	static.HiddifyOptions.ClashApiPort = 0
	static.HiddifyOptions.EnableTun = false
	static.HiddifyOptions.EnableTunService = false
	static.HiddifyOptions.SetSystemProxy = false
	location := configdb.Location{Path: filepath.Join(directory, "catalog.db"), Profile: "verification"}
	content := fmt.Sprintf(`{"outbounds":[{"type":"socks","tag":"server-a","server":"127.0.0.1","server_port":%d},{"type":"socks","tag":"server-b","server":"127.0.0.1","server_port":%d}]}`, a, b)
	if _, err := Parse(ctx, &ParseRequest{ConfigPath: location.String(), Content: content}); err != nil {
		t.Fatal(err)
	}
	options, err := BuildConfig(ctx, &StartRequest{ConfigPath: location.String()})
	if err != nil {
		t.Fatal(err)
	}
	running, err := NewService(ctx, *options)
	if err != nil {
		t.Fatal(err)
	}
	static.StartedService = running
	static.CoreState = CoreStates_STARTED
	defer running.CloseService()
	monitor := monitoring.Get(static.Context())
	out, _ := static.Box().Outbound().Outbound("select")
	selector := out.(*group.Selector)
	for _, mode := range []string{"server-a", "balance", "lowest"} {
		t.Run(mode, func(t *testing.T) {
			for _, tag := range []string{"server-a", "server-b"} {
				report, e := monitor.VerifyAvailability(ctx, tag)
				if e != nil || !report.Reachable || !monitor.CompleteVerification(tag, report.Ticket, true) {
					t.Fatalf("prepare %s %+v %v", tag, report, e)
				}
			}
			time.Sleep(600 * time.Millisecond)
			if !selector.SelectOutbound(mode) {
				t.Fatal("mode selection failed")
			}
			conn, e := out.DialContext(interrupt.ContextWithIsExternalConnection(ctx), "tcp", M.ParseSocksaddr("127.0.0.1:22222"))
			if e != nil {
				t.Fatal(e)
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(10 * time.Second))
			marker := make([]byte, 1)
			if _, e = io.ReadFull(conn, marker); e != nil {
				t.Fatal(e)
			}
			failed := currentVerificationTag()
			report, e := monitor.VerifyAvailability(ctx, failed)
			if e != nil || !report.Reachable {
				t.Fatal(e)
			}
			response, e := (&availabilityService{}).Complete(ctx, &SelectOutboundRequest{GroupTag: report.Ticket, OutboundTag: failed}, false)
			if e != nil || response.Message == "" || response.Message == failed {
				t.Fatalf("did not switch %+v %v", response, e)
			}
			if !monitor.AvailabilityFailed(failed) {
				t.Fatal("failed configuration remained available")
			}
			if mode != "server-a" && selector.Now() != mode {
				t.Fatal("automatic routing mode lost")
			}
			if current := currentVerificationTag(); current == failed || current == "" {
				t.Fatal("Home still reports failed configuration", current)
			}
			for n := 0; n < 20; n++ {
				if _, e = conn.Write([]byte{'x'}); e != nil {
					t.Fatal(e)
				}
				if _, e = io.ReadFull(conn, marker); e != nil || marker[0] != 'x' {
					t.Fatal("existing connection interrupted", e)
				}
			}
		})
	}
}
