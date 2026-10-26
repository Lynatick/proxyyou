package hcore

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"image"
	"image/jpeg"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/interrupt"
	"github.com/sagernet/sing-box/common/monitoring"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/protocol/group"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

type databaseTestTrust struct{ pool *x509.CertPool }

func (s *databaseTestTrust) Name() string                   { return "database-test-trust" }
func (s *databaseTestTrust) Start(adapter.StartStage) error { return nil }
func (s *databaseTestTrust) Close() error                   { return nil }
func (s *databaseTestTrust) Pool() *x509.CertPool           { return s.pool }

func databaseTestCertificate(t *testing.T) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "isolated database test"}, DNSNames: []string{"www.youtube.com", "i.ytimg.com"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		t.Fatal(err)
	}
	key, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(parsed)
	return certificate, pool
}

func databaseTestSOCKS(t *testing.T, marker byte, certificate tls.Certificate) (int, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mutex sync.Mutex
	connections := make(map[net.Conn]bool)
	var workers sync.WaitGroup
	go func() {
		for {
			connection, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			mutex.Lock()
			connections[connection] = true
			mutex.Unlock()
			workers.Add(1)
			go func() {
				defer workers.Done()
				defer connection.Close()
				defer func() { mutex.Lock(); delete(connections, connection); mutex.Unlock() }()
				var err error
				connection.SetDeadline(time.Now().Add(30 * time.Second))
				header := make([]byte, 2)
				if _, err = io.ReadFull(connection, header); err != nil {
					return
				}
				methods := make([]byte, int(header[1]))
				if _, err = io.ReadFull(connection, methods); err != nil {
					return
				}
				connection.Write([]byte{5, 0})
				request := make([]byte, 4)
				if _, err = io.ReadFull(connection, request); err != nil {
					return
				}
				switch request[3] {
				case 1:
					io.CopyN(io.Discard, connection, 4)
				case 4:
					io.CopyN(io.Discard, connection, 16)
				case 3:
					var size [1]byte
					if _, err = io.ReadFull(connection, size[:]); err != nil {
						return
					}
					io.CopyN(io.Discard, connection, int64(size[0]))
				default:
					return
				}
				var port [2]byte
				if _, err = io.ReadFull(connection, port[:]); err != nil {
					return
				}
				connection.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 0})
				if binary.BigEndian.Uint16(port[:]) == 22222 {
					connection.Write([]byte{marker})
					io.Copy(connection, connection)
					return
				}
				secured := tls.Server(connection, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12})
				reader := bufio.NewReader(secured)
				for {
					request, readErr := http.ReadRequest(reader)
					if readErr != nil {
						return
					}
					request.Body.Close()
					time.Sleep(10 * time.Millisecond)
					response := &http.Response{StatusCode: 204, ProtoMajor: 1, ProtoMinor: 1, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(nil)), ContentLength: 0}
					if request.URL.Path != "/generate_204" {
						var data bytes.Buffer
						jpeg.Encode(&data, image.NewRGBA(image.Rect(0, 0, 2, 2)), nil)
						response.StatusCode = 200
						response.Header.Set("Content-Type", "image/jpeg")
						response.Body = io.NopCloser(bytes.NewReader(data.Bytes()))
						response.ContentLength = int64(data.Len())
					}
					if response.Write(secured) != nil {
						return
					}
				}
			}()
		}
	}()
	stop := func() {
		listener.Close()
		mutex.Lock()
		for connection := range connections {
			connection.Close()
		}
		mutex.Unlock()
		workers.Wait()
	}
	return listener.Addr().(*net.TCPAddr).Port, stop
}

func TestDatabaseLiveReloadPreservesConnections(t *testing.T) {
	directory := t.TempDir()
	t.Chdir(directory)
	os.MkdirAll("data", 0700)
	if err := libbox.Setup(&libbox.SetupOptions{BasePath: directory, WorkingPath: directory, TempPath: directory}); err != nil {
		t.Fatal(err)
	}
	certificate, pool := databaseTestCertificate(t)
	alpha, stopAlpha := databaseTestSOCKS(t, 'A', certificate)
	defer stopAlpha()
	beta, stopBeta := databaseTestSOCKS(t, 'B', certificate)
	defer stopBeta()
	ctx := libbox.FromContext(context.Background(), nil)
	ctx = service.ContextWith[adapter.CertificateStore](ctx, &databaseTestTrust{pool: pool})
	previousOptions, previousService, previousState := static.HiddifyOptions, static.StartedService, static.CoreState
	defer func() {
		static.HiddifyOptions = previousOptions
		static.StartedService = previousService
		static.CoreState = previousState
	}()
	static.HiddifyOptions = config.DefaultHiddifyOptions()
	static.HiddifyOptions.MixedPort = 0
	static.HiddifyOptions.DirectPort = 0
	static.HiddifyOptions.RedirectPort = 0
	static.HiddifyOptions.TProxyPort = 0
	static.HiddifyOptions.EnableTunService = false
	static.HiddifyOptions.ClashApiPort = 0
	static.HiddifyOptions.EnableTun = false
	static.HiddifyOptions.SetSystemProxy = false
	location := configdb.Location{Path: filepath.Join(directory, "catalog.db"), Profile: "live-profile"}
	importRevision := func(first int, secondTag string) {
		t.Helper()
		content := fmt.Sprintf(`{"outbounds":[{"type":"socks","tag":"server-a","server":"127.0.0.1","server_port":%d},{"type":"socks","tag":%q,"server":"127.0.0.1","server_port":%d}]}`, first, secondTag, beta)
		if _, err := Parse(ctx, &ParseRequest{ConfigPath: location.String(), Content: content}); err != nil {
			t.Fatal(err)
		}
	}
	importRevision(alpha, "server-b")
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
	selectorValue, _ := static.Box().Outbound().Outbound("select")
	selector := selectorValue.(*group.Selector)
	if !selector.SelectOutbound("server-a") {
		t.Fatal("initial selection failed")
	}
	t.Run("cold automatic group still publishes selection", func(t *testing.T) {
		monitor := monitoring.Get(static.Context())
		automatic, _ := static.Box().Outbound().Outbound("balance")
		if automatic.(adapter.OutboundGroup).Now() != "" {
			t.Fatal("fixture should be a cold round-robin group")
		}
		if !selector.SelectOutbound("server-a") {
			t.Fatal("manual selection failed")
		}
		observer, err := monitor.SubscribeGroup("")
		if err != nil {
			t.Fatal(err)
		}
		defer monitor.UnsubscribeGroup("", observer)
		// Drain the preceding manual selection and health notifications.
		quiet := time.NewTimer(500 * time.Millisecond)
		defer quiet.Stop()
	drain:
		for {
			select {
			case <-observer:
				quiet.Reset(500 * time.Millisecond)
			case <-quiet.C:
				break drain
			}
		}
		for _, tag := range []string{"balance", "lowest"} {
			if !selector.SelectOutbound(tag) {
				t.Fatal("automatic selection failed", tag)
			}
			select {
			case <-observer:
				if selector.Now() != tag {
					t.Fatal("selection snapshot is stale", selector.Now())
				}
			case <-time.After(time.Second):
				t.Fatal("selection change was not published for empty group", tag)
			}
		}
	})
	if !selector.SelectOutbound("server-a") {
		t.Fatal("restore manual selection")
	}
	dial := func(want byte) net.Conn {
		t.Helper()
		connection, dialErr := selector.DialContext(interrupt.ContextWithIsExternalConnection(ctx), "tcp", M.Socksaddr{Addr: netip.MustParseAddr("127.0.0.1"), Port: 22222})
		if dialErr != nil {
			t.Fatal(dialErr)
		}
		connection.SetDeadline(time.Now().Add(10 * time.Second))
		var marker [1]byte
		if _, dialErr = io.ReadFull(connection, marker[:]); dialErr != nil {
			t.Fatal(dialErr)
		}
		if marker[0] != want {
			t.Fatalf("transport %q, expected %q", marker[0], want)
		}
		return connection
	}
	first := dial('A')
	defer first.Close()
	echo := func(connection net.Conn) {
		t.Helper()
		connection.SetDeadline(time.Now().Add(5 * time.Second))
		if _, writeErr := connection.Write([]byte("alive")); writeErr != nil {
			t.Fatal(writeErr)
		}
		buffer := make([]byte, 5)
		if _, readErr := io.ReadFull(connection, buffer); readErr != nil {
			t.Fatal(readErr)
		}
		if string(buffer) != "alive" {
			t.Fatal("connection data changed")
		}
	}
	echo(first)
	originalBox := static.Box()
	importRevision(beta, "server-c")
	response, handled, err := reloadDatabase(ctx, &StartRequest{ConfigPath: location.String(), ConfigName: "updated"})
	if err != nil || !handled || response == nil {
		t.Fatal("live reload failed", handled, err)
	}
	if static.Box() != originalBox {
		t.Fatal("live reload replaced the Box")
	}
	echo(first)
	if selector.SelectOutbound("server-b") {
		t.Fatal("removed server is still selectable")
	}
	if !selector.SelectOutbound("server-a") {
		t.Fatal("replacement server missing")
	}
	second := dial('B')
	echo(second)
	second.Close()
	monitor := monitoring.Get(static.Context())
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		history := monitor.OutboundsHistory("balance")
		if value := history["server-a"]; value != nil && !value.IsFromCache && value.Delay > 0 && value.Delay < monitoring.TimeoutDelay {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	for _, mode := range []string{"balance", "server-a", "lowest", "server-c"} {
		if !selector.SelectOutbound(mode) {
			t.Fatal("selection failed", mode)
		}
		connection := dial('B')
		echo(connection)
		connection.Close()
		echo(first)
	}
	// Force the final SQL activation to fail after providers have been staged.
	// The old typed source and both old established/new requests must recover.
	importRevision(alpha, "server-d")
	catalog, openErr := configdb.Open(ctx, location.Path)
	if openErr != nil {
		t.Fatal(openErr)
	}
	defer catalog.Close()
	failedRevision, resolveErr := catalog.Resolve(ctx, location.Profile, "")
	if resolveErr != nil {
		t.Fatal(resolveErr)
	}
	if _, err = catalog.DB.Exec("CREATE TRIGGER force_activation_failure BEFORE INSERT ON configuration_runtime WHEN NEW.revision='" + failedRevision + "' BEGIN SELECT RAISE(ABORT,'forced activation failure'); END"); err != nil {
		t.Fatal(err)
	}
	_, err = Restart(ctx, &StartRequest{ConfigPath: location.String()})
	if err == nil {
		t.Fatal("activation failure did not reach caller", err)
	}
	if static.Box() != originalBox || static.CoreState != CoreStates_STARTED {
		t.Fatal("recovery replaced or stopped the running Box")
	}
	if !selector.SelectOutbound("server-a") {
		t.Fatal("rollback lost prior server")
	}
	recovered := dial('B')
	echo(recovered)
	recovered.Close()
	echo(first)
	if selector.SelectOutbound("server-d") {
		t.Fatal("failed revision leaked into selector")
	}

}
