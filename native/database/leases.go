package configdb

import (
	"context"
	"fmt"
	"github.com/google/uuid"
	"os"
	"time"
)

func (s *Store) Pin(ctx context.Context, location Location) (string, string, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()
	revision := location.Revision
	if revision == "" {
		if err = tx.QueryRowContext(ctx, "SELECT revision FROM subscription_active WHERE profile_id=?", location.Profile).Scan(&revision); err != nil {
			return "", "", err
		}
	}
	var state string
	var codec int
	if err = tx.QueryRowContext(ctx, "SELECT state,codec FROM subscription_revisions WHERE id=? AND profile_id=?", revision, location.Profile).Scan(&state, &codec); err != nil {
		return "", "", err
	}
	if state != "ready" || codec != CodecVersion {
		return "", "", fmt.Errorf("incomplete or unsupported configuration revision")
	}
	token := uuid.NewString()
	if _, err = tx.ExecContext(ctx, "INSERT INTO configuration_revision_leases VALUES(?,?,?,?)", token, revision, os.Getpid(), time.Now().UnixMilli()); err != nil {
		return "", "", err
	}
	if err = tx.Commit(); err != nil {
		return "", "", err
	}
	return revision, token, nil
}
func (s *Store) Unpin(token string) {
	s.DB.Exec("DELETE FROM configuration_revision_leases WHERE token=?", token)
}
func (s *Store) cleanupDeadLeases() {
	rows, err := s.DB.Query("SELECT DISTINCT owner_pid FROM configuration_revision_leases")
	if err != nil {
		return
	}
	var dead []int
	for rows.Next() {
		var pid int
		if rows.Scan(&pid) == nil && !processAlive(pid) {
			dead = append(dead, pid)
		}
	}
	rows.Close()
	for _, pid := range dead {
		s.DB.Exec("DELETE FROM configuration_revision_leases WHERE owner_pid=?", pid)
	}
}
func (s *Store) Cleanup(profile string) {
	// Never delete a revision held by another core instance or an open UI view.
	// Keep the current and the previous complete catalogue for recovery.
	s.DB.Exec("DELETE FROM subscription_revisions WHERE profile_id=? AND state='deleted' AND id NOT IN(SELECT revision FROM configuration_revision_leases)", profile)
	s.DB.Exec(`DELETE FROM subscription_revisions WHERE profile_id=? AND state='ready'
 AND id NOT IN(SELECT revision FROM subscription_active)
 AND id NOT IN(SELECT revision FROM configuration_revision_leases)
 AND id NOT IN(SELECT id FROM subscription_revisions WHERE profile_id=? AND state='ready' ORDER BY created DESC,id DESC LIMIT 2)`, profile, profile)
}

// Only a dead importing process can leave unfinished batches. Never reclaim
// staging rows solely by age while a large subscription is still importing.
func (s *Store) cleanupDeadImports() {
	rows, err := s.DB.Query("SELECT DISTINCT owner_pid FROM configuration_imports")
	if err != nil {
		return
	}
	var dead []int
	for rows.Next() {
		var pid int
		if rows.Scan(&pid) == nil && !processAlive(pid) {
			dead = append(dead, pid)
		}
	}
	rows.Close()
	for _, pid := range dead {
		s.DB.Exec("DELETE FROM subscription_revisions WHERE state='staging' AND id IN(SELECT revision FROM configuration_imports WHERE owner_pid=?)", pid)
	}
}
