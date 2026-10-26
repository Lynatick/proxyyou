package monitoring

import (
	"context"
	"testing"
	"time"
)

func TestSelectionNotificationsCoalesceWithoutBlocking(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pending := make(chan struct{}, 1)
	pending <- struct{}{}
	monitor := &OutboundMonitoring{
		groups: map[string]*groupState{"select": {tag: "select", notifyCh: pending, observer: NewBroadcaster[GroupEvent](ctx)}},
	}
	done := make(chan error, 1)
	go func() { monitor.SelectionChanged("select"); done <- nil }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
		if len(pending) != 1 {
			t.Fatal("pending notification was lost")
		}
	case <-time.After(time.Second):
		<-pending // Release the old implementation's blocked sender.
		<-done
		t.Fatal("a queued UI notification blocked a control operation")
	}
}
