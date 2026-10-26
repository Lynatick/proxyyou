package configdb

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-box/option"
)

func Load(ctx context.Context, location Location) (*option.Options, error) {
	store, err := Open(ctx, location.Path)
	if err != nil {
		return nil, err
	}
	success := false
	defer func() {
		if !success {
			store.Close()
		}
	}()
	revision, token, err := store.Pin(ctx, location)
	if err != nil {
		return nil, err
	}
	defer func() {
		if !success {
			store.Unpin(token)
		}
	}()
	var options option.Options
	if err = store.ReadFields(ctx, revision, 0, &options); err != nil {
		return nil, err
	}
	entries, err := store.Entries(ctx, revision)
	if err != nil {
		return nil, err
	}
	fingerprints, err := dependencyFingerprints(entries)
	if err != nil {
		return nil, err
	}
	location.Revision = revision
	source := &option.DatabaseSourceOptions{Location: location.String(), Profile: location.Profile, Revision: revision, Close: store.Close}
	status := store.statusWriter(ctx, location.Profile, revision, entries, token)
	source.Record = status.record
	source.RecordUsage = status.recordUsage
	source.ReadSelection = func(group string) string {
		var tag string
		store.DB.QueryRow("SELECT tag FROM configuration_selections WHERE profile_id=? AND group_tag=?", location.Profile, group).Scan(&tag)
		return tag
	}
	source.StoreSelection = func(group, tag string) error {
		result, saveErr := store.DB.Exec("INSERT INTO configuration_selections SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM subscription_active WHERE profile_id=?) ON CONFLICT(profile_id,group_tag) DO UPDATE SET tag=excluded.tag", location.Profile, group, tag, location.Profile)
		if saveErr == nil {
			if count, err := result.RowsAffected(); err != nil {
				return err
			} else if count == 0 {
				return fmt.Errorf("subscription was deleted")
			}
		}
		return saveErr
	}
	source.Activate = func() error {
		result, activateErr := store.DB.ExecContext(ctx, "INSERT INTO configuration_runtime(profile_id,revision,session,updated,network_epoch) SELECT ?,?,?,?,0 WHERE EXISTS(SELECT 1 FROM subscription_revisions WHERE id=? AND profile_id=? AND state='ready') ON CONFLICT(profile_id) DO UPDATE SET revision=excluded.revision,session=excluded.session,updated=excluded.updated,network_epoch=0", location.Profile, revision, status.session, time.Now().UnixMilli(), revision, location.Profile)
		if activateErr == nil {
			if count, err := result.RowsAffected(); err != nil {
				return err
			} else if count == 0 {
				return fmt.Errorf("subscription was deleted before activation")
			}
		}
		return activateErr
	}
	source.NetworkChanged = func(epoch uint64) {
		store.DB.Exec("UPDATE configuration_runtime SET network_epoch=? WHERE profile_id=? AND session=?", epoch, location.Profile, status.session)
	}
	source.ReadHistory = func() ([]option.DatabaseHistory, error) {
		rows, queryErr := store.DB.QueryContext(ctx, "SELECT e.tag,s.delay,s.unavailable,s.checked FROM configuration_status s JOIN configuration_entries e ON e.revision=s.revision AND e.id=s.entry_id WHERE s.revision=?", revision)
		if queryErr != nil {
			return nil, queryErr
		}
		defer rows.Close()
		var history []option.DatabaseHistory
		for rows.Next() {
			var item option.DatabaseHistory
			var checked int64
			if queryErr = rows.Scan(&item.Tag, &item.Delay, &item.Unavailable, &checked); queryErr != nil {
				return nil, queryErr
			}
			item.Time = time.UnixMilli(checked)
			history = append(history, item)
		}
		return history, rows.Err()
	}
	var closeOnce sync.Once
	source.Close = func() error {
		var closeErr error
		closeOnce.Do(func() { status.close(); store.Unpin(token); store.Cleanup(location.Profile); closeErr = store.Close() })
		return closeErr
	}
	options.DatabaseSource = source
	for _, entry := range entries {
		current := entry
		var parameters any
		if entry.IsGroup {
			parameters, err = store.ReadOptions(ctx, revision, entry)
			if err != nil {
				source.Close()
				return nil, err
			}
		} else {
			parameters = &option.DeferredOutboundOptions{Fingerprint: fingerprints[entry.Tag], Network: entry.Network, Dependencies: entry.Dependencies, Display: entry.Display,
				Load: func(loadCtx context.Context) (any, error) { return store.ReadOptions(loadCtx, revision, current) }}
		}
		switch entry.Section {
		case "outbounds":
			options.Outbounds = append(options.Outbounds, option.Outbound{Type: entry.Type, Tag: entry.Tag, Options: parameters})
		case "endpoints":
			options.Endpoints = append(options.Endpoints, option.Endpoint{Type: entry.Type, Tag: entry.Tag, Options: parameters})
		default:
			source.Close()
			return nil, fmt.Errorf("unknown configuration section")
		}
	}
	success = true
	return &options, nil
}

type statusRecord struct {
	entry           int64
	delay           uint16
	unavailable     bool
	epoch, sequence uint64
	checked         int64
}
type statusWriter struct {
	store             *Store
	revision, session string
	ids               map[string]int64
	mu                sync.Mutex
	pending           map[int64]statusRecord
	wake              chan struct{}
	stop              chan struct{}
	done              chan struct{}
	once              sync.Once
	closed            bool
	usage             map[int64][2]int64
	sequence          atomic.Uint64
}

func (s *Store) statusWriter(ctx context.Context, profile, revision string, entries []Entry, session string) *statusWriter {
	writer := &statusWriter{store: s, revision: revision, session: session, ids: make(map[string]int64, len(entries)), pending: make(map[int64]statusRecord), usage: make(map[int64][2]int64), wake: make(chan struct{}, 1), stop: make(chan struct{}), done: make(chan struct{})}
	for _, entry := range entries {
		writer.ids[entry.Tag] = entry.ID
	}
	go writer.run()
	return writer
}
func (w *statusWriter) record(tag string, delay uint16, unavailable bool, _ string, epoch, _ uint64) {
	id, ok := w.ids[tag]
	if !ok {
		return
	}
	sequence := w.sequence.Add(1)
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.pending[id] = statusRecord{entry: id, delay: delay, unavailable: unavailable, epoch: epoch, sequence: sequence, checked: time.Now().UnixMilli()}
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
}
func (w *statusWriter) recordUsage(values map[string][2]int64) {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	for tag, value := range values {
		if id, ok := w.ids[tag]; ok {
			w.usage[id] = value
		}
	}
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
}
func (w *statusWriter) flush() {
	w.mu.Lock()
	records := w.pending
	usage := w.usage
	w.pending = make(map[int64]statusRecord)
	w.usage = make(map[int64][2]int64)
	w.mu.Unlock()
	if len(records) == 0 && len(usage) == 0 {
		return
	}
	success := false
	defer func() {
		if !success {
			w.mu.Lock()
			for id, value := range records {
				if newer, ok := w.pending[id]; !ok || newer.sequence < value.sequence {
					w.pending[id] = value
				}
			}
			for id, value := range usage {
				if _, ok := w.usage[id]; !ok {
					w.usage[id] = value
				}
			}
			w.mu.Unlock()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := w.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return
	}
	defer tx.Rollback()
	statement, err := tx.PrepareContext(ctx, `INSERT INTO configuration_status SELECT ?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM configuration_runtime WHERE revision=? AND session=?) ON CONFLICT(revision,entry_id) DO UPDATE SET session=excluded.session,network_epoch=excluded.network_epoch,sequence=excluded.sequence,delay=excluded.delay,unavailable=excluded.unavailable,checked=excluded.checked WHERE configuration_status.session<>excluded.session OR configuration_status.sequence<excluded.sequence`)
	if err != nil {
		return
	}
	defer statement.Close()
	for _, record := range records {
		if _, err = statement.ExecContext(ctx, w.revision, record.entry, w.session, record.epoch, record.sequence, record.delay, record.unavailable, record.checked, w.revision, w.session); err != nil {
			return
		}
	}
	for id, value := range usage {
		if _, err = tx.ExecContext(ctx, `INSERT INTO configuration_usage SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM configuration_runtime WHERE revision=? AND session=?) ON CONFLICT(revision,entry_id) DO UPDATE SET session=excluded.session,upload=excluded.upload,download=excluded.download`, w.revision, id, w.session, value[0], value[1], w.revision, w.session); err != nil {
			return
		}
	}
	success = tx.Commit() == nil
}
func (w *statusWriter) run() {
	defer close(w.done)
	retry := time.NewTicker(time.Second)
	defer retry.Stop()
	for {
		select {
		case <-w.stop:
			w.flush()
			return
		case <-retry.C:
			w.flush()
		case <-w.wake:
			timer := time.NewTimer(20 * time.Millisecond)
			select {
			case <-timer.C:
			case <-w.stop:
				timer.Stop()
				w.flush()
				return
			}
			w.flush()
		}
	}
}
func (w *statusWriter) close() {
	w.once.Do(func() { w.mu.Lock(); w.closed = true; w.mu.Unlock(); close(w.stop); <-w.done })
}
