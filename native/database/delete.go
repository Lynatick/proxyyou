package configdb

import (
	"context"
	"database/sql"
	"fmt"
)

// Deletion retires catalogues. Pinned UI views and live connections retain
// their exact revision until their owners release it.
func (s *Store) DeleteProfile(ctx context.Context, profile string) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var live int
	activeErr := tx.QueryRowContext(ctx, "SELECT 1 FROM configuration_runtime r JOIN configuration_revision_leases l ON l.token=r.session WHERE r.profile_id=? LIMIT 1", profile).Scan(&live)
	if activeErr == nil {
		return fmt.Errorf("Сначала отключите подключение этой подписки.")
	}
	if activeErr != sql.ErrNoRows {
		return activeErr
	}

	for _, statement := range []string{
		"DELETE FROM subscription_active WHERE profile_id=?",
		"DELETE FROM configuration_selections WHERE profile_id=?",
		"DELETE FROM configuration_runtime WHERE profile_id=?",
		"UPDATE subscription_revisions SET state='deleted' WHERE profile_id=?",
		"DELETE FROM subscription_revisions WHERE profile_id=? AND id NOT IN(SELECT revision FROM configuration_revision_leases)",
	} {
		if _, err = tx.ExecContext(ctx, statement, profile); err != nil {
			return err
		}
	}
	return tx.Commit()
}
