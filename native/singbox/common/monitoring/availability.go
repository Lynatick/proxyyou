package monitoring

import (
	"context"
	cryptorand "crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/common/ntp"
)

type AvailabilityResult struct {
	Label       string `json:"label"`
	Outcome     string `json:"outcome"`
	ElapsedMS   int64  `json:"elapsed_ms"`
	StatusCode  int    `json:"status_code,omitempty"`
	TLSReason   string `json:"tls_reason,omitempty"`
	IsThumbnail bool   `json:"is_thumbnail"`
}

type AvailabilityReport struct {
	Tag         string               `json:"tag"`
	Reachable   bool                 `json:"reachable"`
	Checks      []AvailabilityResult `json:"checks"`
	Ping        *AvailabilityResult  `json:"ping,omitempty"`
	Ticket      string               `json:"ticket,omitempty"`
	IntervalMS  int64                `json:"interval_ms,omitempty"`
	completedAt time.Time
}

func (r AvailabilityReport) Delay() uint16 {
	if len(r.Checks) == 0 {
		return TimeoutDelay
	}
	delay := r.Checks[0].ElapsedMS
	if delay < 1 {
		delay = 1
	}
	if delay >= int64(TimeoutDelay) {
		delay = int64(TimeoutDelay) - 1
	}
	return uint16(delay)
}

// Shared with regular URL tests: at most 20 servers are checked concurrently.
func (m *OutboundMonitoring) acquireProbeSlot(ctx context.Context) (func(), error) {
	m.probeOnce.Do(func() { m.probeSlots = make(chan struct{}, defaultWorkerCount) })
	select {
	case m.probeSlots <- struct{}{}:
		return func() { <-m.probeSlots }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (m *OutboundMonitoring) AvailabilityFailed(tag string) bool {
	state := m.state(tag)
	if state == nil {
		return false
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.availabilityFailed
}

// Pin both requests to one concrete outbound. A group can route each request to
// another node, so its last-selected label is never accepted as a probe route.
func (m *OutboundMonitoring) CheckAvailability(parent context.Context, tag string) (AvailabilityReport, error) {
	return m.checkAvailability(parent, tag, false)
}

// VerifyAvailability gates each stage on fresh evidence from the same concrete server.
func (m *OutboundMonitoring) VerifyAvailability(parent context.Context, tag string) (AvailabilityReport, error) {
	return m.checkAvailability(parent, tag, true)
}

func (m *OutboundMonitoring) checkAvailability(parent context.Context, tag string, sequential bool) (AvailabilityReport, error) {
	interval := m.mainInterval
	if interval <= 0 {
		interval = defaultInterval
	}
	report := AvailabilityReport{Tag: tag, Reachable: true, IntervalMS: interval.Milliseconds(), Checks: []AvailabilityResult{}}
	state := m.state(tag)
	if state == nil {
		return report, fmt.Errorf("outbound not registered")
	}
	if _, group := m.lookupGroup(tag); group {
		return report, fmt.Errorf("availability requires a concrete outbound")
	}
	timeout := 12 * time.Second
	if sequential {
		timeout = 20 * time.Second
	}
	ctx, cancel := context.WithTimeout(m.ctx, timeout)
	defer cancel()
	stop := context.AfterFunc(parent, cancel)
	defer stop()
	epoch := m.networkEpoch.Load()
	state.mu.Lock()
	state.availabilitySequence++
	seq := state.availabilitySequence
	verificationSeq := uint64(0)
	if sequential {
		var nonce [8]byte
		if _, err := cryptorand.Read(nonce[:]); err != nil {
			state.mu.Unlock()
			return report, err
		}
		state.verificationSequence = binary.LittleEndian.Uint64(nonce[:])
		if state.verificationSequence == 0 {
			state.verificationSequence = 1
		}
		verificationSeq = state.verificationSequence
		state.verificationReady = false
		report.Ticket = fmt.Sprintf("%d:%d:%s", epoch, verificationSeq, tag)
	}
	state.mu.Unlock()
	release, err := m.acquireProbeSlot(ctx)
	if err != nil {
		return report, err
	}
	defer release()
	if sequential {
		timeout := m.urlTestTimeout
		if timeout <= 0 {
			timeout = defaultURLTestTimeout
		}
		pingCtx, pingCancel := context.WithTimeout(ctx, timeout)
		began := time.Now()
		delay, pingErr := urltest.URLTest(pingCtx, defaultURLTest, state.outbound)
		pingCancel()
		ping := AvailabilityResult{Label: "Пинг", Outcome: "reachable", ElapsedMS: time.Since(began).Milliseconds()}
		if pingErr != nil || delay >= TimeoutDelay {
			ping.Outcome = "networkFailure"
			var timed net.Error
			if errors.Is(pingErr, context.DeadlineExceeded) || errors.As(pingErr, &timed) && timed.Timeout() {
				ping.Outcome = "timeout"
			}
			report.Reachable = false
		}
		report.Ping = &ping
	}
	for _, target := range []struct {
		label, url string
		status     int
		thumbnail  bool
	}{
		{"YouTube", "https://www.youtube.com/generate_204", 204, false},
		{"Миниатюры", "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg", 200, true},
	} {
		if !report.Reachable {
			// Keep the legacy two-row wire format without issuing a later request.
			if !sequential {
				report.Checks = append(report.Checks, AvailabilityResult{Label: target.label, Outcome: "skipped", IsThumbnail: target.thumbnail})
			}
			continue
		}
		result := checkAvailabilityTarget(ctx, m.ctx, state.outbound, target.label, target.url, target.status, target.thumbnail)
		report.Checks = append(report.Checks, result)
		if result.Outcome != "reachable" {
			report.Reachable = false
		}
	}
	m.sourceEpochMu.RLock()
	defer m.sourceEpochMu.RUnlock()
	// UI disposal, disconnect and network changes do not blacklist a server.
	if parent.Err() != nil || m.ctx.Err() != nil || epoch != m.networkEpoch.Load() {
		return report, context.Canceled
	}
	state.mu.Lock()
	if seq != state.availabilitySequence || epoch != m.networkEpoch.Load() || parent.Err() != nil || m.ctx.Err() != nil {
		state.mu.Unlock()
		return report, context.Canceled
	}
	state.availabilityFailed = !report.Reachable || state.proofFailed
	if sequential && verificationSeq == state.verificationSequence {
		state.verificationReady = report.Reachable
	}
	m.cacheDirty.Store(true)
	report.completedAt = time.Now()
	state.history.Time = report.completedAt
	if report.Reachable {
		state.history.Delay = report.Delay()
		state.from_cache = false
	}
	if m.database() != nil && m.database().Record != nil {
		delay := state.history.Delay
		if state.availabilityFailed {
			delay = TimeoutDelay
		}
		m.database().Record(tag, delay, state.availabilityFailed, "", epoch, seq)
	}
	groups := append([]string(nil), state.groupTags...)
	state.mu.Unlock()
	m.emitGroupEvent(groups)
	return report, nil
}

func checkAvailabilityTarget(ctx, coreCtx context.Context, out adapter.Outbound, label, address string, expected int, thumbnail bool) (result AvailabilityResult) {
	start := time.Now()
	result = AvailabilityResult{Label: label, Outcome: "networkFailure", IsThumbnail: thumbnail}
	defer func() { result.ElapsedMS = time.Since(start).Milliseconds() }()
	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return out.DialContext(ctx, network, M.ParseSocksaddr(address))
		},
		TLSClientConfig:   &tls.Config{RootCAs: adapter.RootPoolFromContext(coreCtx), Time: ntp.TimeFuncFromContext(coreCtx)},
		DisableKeepAlives: true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return result
	}
	response, err := client.Do(request)
	if err != nil {
		var certInvalid x509.CertificateInvalidError
		var hostname x509.HostnameError
		var unknownCA x509.UnknownAuthorityError
		var certVerification *tls.CertificateVerificationError
		var timeout net.Error
		switch {
		case errors.Is(err, context.DeadlineExceeded), errors.As(err, &timeout) && timeout.Timeout():
			result.Outcome = "timeout"
		case errors.As(err, &certInvalid):
			result.Outcome = "tlsFailure"
			result.TLSReason = "handshake"
			if certInvalid.Reason == x509.Expired {
				result.TLSReason = "certificateExpired"
			}
		case errors.As(err, &hostname):
			result.Outcome = "tlsFailure"
			result.TLSReason = "hostnameMismatch"
		case errors.As(err, &unknownCA), errors.As(err, &certVerification):
			result.Outcome = "tlsFailure"
			result.TLSReason = "untrustedCertificate"
		default:
			if strings.Contains(strings.ToLower(err.Error()), "tls") {
				result.Outcome = "tlsFailure"
				result.TLSReason = "handshake"
			}
		}
		return result
	}
	defer response.Body.Close()
	result.StatusCode = response.StatusCode
	if response.StatusCode != expected {
		result.Outcome = "rejected"
		return result
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 256*1024+1))
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			result.Outcome = "timeout"
		}
		return result
	}
	valid := len(body) == 0
	if thumbnail {
		valid = strings.HasPrefix(strings.ToLower(response.Header.Get("Content-Type")), "image/jpeg") && len(body) >= 3 && body[0] == 0xff && body[1] == 0xd8 && body[2] == 0xff
	}
	result.Outcome = "unexpectedResponse"
	if valid && len(body) <= 256*1024 {
		result.Outcome = "reachable"
	}
	return result
}

// database-catalog-snapshot-access
