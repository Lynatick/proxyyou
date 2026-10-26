package configdb

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
)

const SettingsScheme = "proxyyou-settings"

func SettingsLocation(path, version string) string {
	u := databaseURL(SettingsScheme, path)
	u.RawQuery = url.Values{"revision": {version}}.Encode()
	return u.String()
}
func ReadSettings(ctx context.Context, location string, target any) (bool, error) {
	if !strings.HasPrefix(location, SettingsScheme+":") {
		return false, nil
	}
	parsed, err := url.Parse(location)
	if err != nil {
		return true, err
	}
	path := filesystemPath(parsed.Path)
	if parsed.Host != "" || path == "" || parsed.Query().Get("revision") == "" {
		return true, fmt.Errorf("invalid settings database location")
	}
	store, err := Open(ctx, path)
	if err != nil {
		return true, err
	}
	defer store.Close()
	tx, err := store.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return true, err
	}
	defer tx.Rollback()
	version := parsed.Query().Get("revision")
	var representation, state string
	if err = tx.QueryRowContext(ctx, "SELECT representation,state FROM application_options WHERE id=?", version).Scan(&representation, &state); err != nil {
		return true, err
	}
	if state != "ready" {
		return true, fmt.Errorf("incomplete settings revision")
	}
	rows, err := tx.QueryContext(ctx, "SELECT path,kind,type_name,text_value,int_value,real_value,blob_value FROM application_option_fields WHERE version=?", version)
	if err != nil {
		return true, err
	}
	var fields []Field
	for rows.Next() {
		var field Field
		if err = rows.Scan(&field.Path, &field.Kind, &field.Type, &field.Text, &field.Number, &field.Real, &field.Bytes); err != nil {
			rows.Close()
			return true, err
		}
		fields = append(fields, field)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return true, err
	}
	if err = tx.Commit(); err != nil {
		return true, err
	}
	if representation == "typed" {
		return true, NewCodec(target).Decode(fields, target)
	}
	if representation != "semantic" {
		return true, fmt.Errorf("unknown settings representation")
	}
	var values map[string]any
	if err = NewCodec().Decode(fields, &values); err != nil {
		return true, err
	}
	return true, AssignSemantic(values, target)
}
func (s *Store) SaveTypedSettings(ctx context.Context, value any) (string, error) {
	fields, err := NewCodec(value).Encode(value)
	if err != nil {
		return "", err
	}
	version := uuid.NewString()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "INSERT INTO application_options VALUES(?,'ready','typed',?)", version, time.Now().UnixMilli()); err != nil {
		return "", err
	}
	statement, err := tx.PrepareContext(ctx, "INSERT INTO application_option_fields VALUES(?,?,?,?,?,?,?,?)")
	if err != nil {
		return "", err
	}
	defer statement.Close()
	for _, field := range fields {
		if _, err = statement.ExecContext(ctx, version, field.Path, field.Kind, field.Type, field.Text, field.Number, field.Real, field.Bytes); err != nil {
			return "", err
		}
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	return version, nil
}
