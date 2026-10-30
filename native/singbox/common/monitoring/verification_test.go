package monitoring

import (
	"context"
	"net/http"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestProxyYouVerificationSequentialGates(t *testing.T) {
	for _, stage := range []string{"ping", "youtube", "thumbnail", "success"} {
		t.Run(stage, func(t *testing.T) {
			var mu sync.Mutex
			var requests []string
			m, _ := availabilityFixture(t, func(w http.ResponseWriter, r *http.Request) {
				label := "youtube"
				if r.Method == "HEAD" {
					label = "ping"
				} else if r.Host == "i.ytimg.com" {
					label = "thumbnail"
				}
				mu.Lock()
				requests = append(requests, label)
				mu.Unlock()
				if stage == label {
					if label == "ping" {
						<-r.Context().Done()
						return
					}
					w.WriteHeader(503)
					return
				}
				availabilityReply(w, r, 200)
			})
			m.urlTestTimeout = 40 * time.Millisecond
			m.mainInterval = 17 * time.Minute
			report, err := m.VerifyAvailability(context.Background(), "a")
			if err != nil {
				t.Fatal(err)
			}
			want := []string{"ping", "youtube", "thumbnail"}
			if stage == "ping" {
				want = want[:1]
			} else if stage == "youtube" {
				want = want[:2]
			}
			mu.Lock()
			got := append([]string(nil), requests...)
			mu.Unlock()
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("stages: got %v want %v", got, want)
			}
			if report.Reachable != (stage == "success") {
				t.Fatalf("false success: %+v", report)
			}
			if report.IntervalMS != (17 * time.Minute).Milliseconds() {
				t.Fatal("lost subscription interval")
			}
			if report.Ping == nil || report.Checks == nil {
				t.Fatal("missing ping/empty-stage wire evidence")
			}
			if stage != "success" && !m.AvailabilityFailed("a") {
				t.Fatal("failed configuration stayed eligible for automatic groups")
			}
		})
	}
}

func TestProxyYouVerificationCanceledPrerequisiteCannotAdvanceOrBlacklist(t *testing.T) {
	entered := make(chan struct{})
	m, _ := availabilityFixture(t, func(w http.ResponseWriter, r *http.Request) { close(entered); <-r.Context().Done() })
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := m.VerifyAvailability(ctx, "a"); done <- err }()
	<-entered
	cancel()
	if err := <-done; err == nil {
		t.Fatal("cancellation accepted")
	}
	if m.AvailabilityFailed("a") {
		t.Fatal("canceled route was blacklisted")
	}
}

func TestProxyYouLegacyAvailabilityAlsoStopsBeforeThumbnailOnYouTubeFailure(t *testing.T) {
	var mu sync.Mutex
	var requests []string
	m, _ := availabilityFixture(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		requests = append(requests, r.Host)
		mu.Unlock()
		w.WriteHeader(503)
	})
	report, err := m.CheckAvailability(context.Background(), "a")
	if err != nil || report.Reachable || len(report.Checks) != 2 || report.Checks[1].Outcome != "skipped" {
		t.Fatalf("%+v %v", report, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if !reflect.DeepEqual(requests, []string{"www.youtube.com"}) {
		t.Fatal("failure advanced background/legacy requests", requests)
	}
}

func TestVerificationVideoFailureSurvivesSuccessfulPingAndNetworkUntilFullProof(t *testing.T) {
	m, _ := availabilityFixture(t, func(w http.ResponseWriter, r *http.Request) { availabilityReply(w, r, 200) })
	report, err := m.VerifyAvailability(context.Background(), "a")
	if err != nil || !report.Reachable || report.Ticket == "" {
		t.Fatalf("%+v %v", report, err)
	}
	if !m.CompleteVerification("a", report.Ticket, false) || !m.AvailabilityFailed("a") {
		t.Fatal("video failure was not applied")
	}
	if m.CompleteVerification("a", report.Ticket, true) {
		t.Fatal("a consumed proof cleared a failure")
	}
	if _, err = m.CheckAvailability(context.Background(), "a"); err != nil || !m.AvailabilityFailed("a") {
		t.Fatal("network-only check cleared video failure")
	}
	fresh, err := m.VerifyAvailability(context.Background(), "a")
	if err != nil || !fresh.Reachable || !m.AvailabilityFailed("a") {
		t.Fatal("network stage admitted a failed video")
	}
	if m.CompleteVerification("a", report.Ticket, true) {
		t.Fatal("stale ticket accepted")
	}
	if !m.CompleteVerification("a", fresh.Ticket, true) || m.AvailabilityFailed("a") {
		t.Fatal("complete proof did not recover server")
	}
	if m.CompleteVerification("a", fresh.Ticket, false) {
		t.Fatal("late failure overwrote recovery")
	}
	m.networkEpoch.Add(1)
	if m.CompleteVerification("a", fresh.Ticket, false) {
		t.Fatal("old network ticket accepted")
	}
}

func TestVerificationFailureCannotPassWithoutNetworkOrInventFallback(t *testing.T) {
	m, _ := availabilityFixture(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) })
	report, err := m.VerifyAvailability(context.Background(), "a")
	if err != nil || report.Reachable {
		t.Fatal(err)
	}
	if m.CompleteVerification("a", report.Ticket, true) {
		t.Fatal("failed prerequisite accepted as full proof")
	}
	if !m.CompleteVerification("a", report.Ticket, false) {
		t.Fatal("failure rejected")
	}
	m.outboundOrder = []string{"a"}
	if m.NextVerificationTag("a") != "" {
		t.Fatal("all-failed pool invented a fallback")
	}
}
