package configdb

import (
	"context"
	"crypto/sha256"
	"database/sql"
	_ "embed"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	_ "github.com/mattn/go-sqlite3"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/service"
	"github.com/sagernet/sing/service/filemanager"
)

const SchemaVersion = 1
const Scheme = "proxyyou-db"

//go:embed schema.sql
var schemaDDL string

type Location struct{ Path, Profile, Revision string }

func ParseLocation(value string) (Location, bool, error) {
	if !strings.HasPrefix(value, Scheme+":") {
		return Location{}, false, nil
	}
	u, err := url.Parse(value)
	if err != nil {
		return Location{}, true, err
	}
	if u.Host != "" || u.Path == "" || u.Query().Get("profile") == "" {
		return Location{}, true, fmt.Errorf("invalid database configuration location")
	}
	path := filesystemPath(u.Path)
	return Location{Path: path, Profile: u.Query().Get("profile"), Revision: u.Query().Get("revision")}, true, nil
}
func (l Location) String() string {
	u := databaseURL(Scheme, l.Path)
	q := url.Values{"profile": {l.Profile}}
	if l.Revision != "" {
		q.Set("revision", l.Revision)
	}
	u.RawQuery = q.Encode()
	return u.String()
}

type Store struct {
	DB      *sql.DB
	codec   *Codec
	context context.Context
}
type Descriptor struct {
	Network, Dependencies []string
	Display               string
	IsGroup               bool
}
type Entry struct {
	ID                              int64
	Section                         string
	Ordinal                         int
	Tag, Type, Display, Fingerprint string
	IsGroup                         bool
	Network, Dependencies           []string
}

type optionRegistry interface {
	OptionTypes() []string
	CreateOptions(string) (any, bool)
}

func ContextCodec(ctx context.Context) *Codec {
	c := NewCodec(option.Options{})
	registries := []any{
		service.FromContext[option.OutboundOptionsRegistry](ctx), service.FromContext[option.EndpointOptionsRegistry](ctx),
		service.FromContext[option.InboundOptionsRegistry](ctx), service.FromContext[option.DNSTransportOptionsRegistry](ctx),
		service.FromContext[option.ServiceOptionsRegistry](ctx),
	}
	for _, value := range registries {
		if registry, ok := value.(optionRegistry); ok {
			for _, name := range registry.OptionTypes() {
				if prototype, ok := registry.CreateOptions(name); ok {
					c.Register(prototype)
				}
			}
		}
	}
	return c
}

func Open(ctx context.Context, path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	file, err := os.OpenFile(absolute, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = file.Close(); err != nil {
		return nil, err
	}
	if err = os.Chmod(absolute, 0600); err != nil {
		return nil, err
	}
	u := databaseURL("file", absolute)
	q := url.Values{"_journal_mode": {"WAL"}, "_foreign_keys": {"on"}, "_busy_timeout": {"5000"}, "_synchronous": {"FULL"}, "_txlock": {"immediate"}}
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlite3", u.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(8)
	s := &Store{DB: db, codec: ContextCodec(ctx), context: ctx}
	if err = s.initialize(); err != nil {
		db.Close()
		return nil, err
	}
	for _, file := range []string{absolute, absolute + "-wal", absolute + "-shm"} {
		if _, statErr := os.Stat(file); statErr == nil {
			if err = filemanager.Chown(ctx, file); err != nil {
				db.Close()
				return nil, err
			}
		}
	}
	s.cleanupDeadLeases()
	s.cleanupDeadImports()
	return s, nil
}
func (s *Store) Close() error { return s.DB.Close() }
func (s *Store) initialize() error {
	var version int
	if err := s.DB.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version > SchemaVersion {
		return fmt.Errorf("configuration database is newer than this core")
	}
	if version == SchemaVersion {
		return nil
	}
	_, err := s.DB.Exec(schemaDDL)
	return err
}

func (s *Store) Import(ctx context.Context, profile string, options *option.Options, descriptors map[string]Descriptor, sourceHash string) (revision string, err error) {
	revision = uuid.NewString()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var previous string
	err = tx.QueryRowContext(ctx, "SELECT revision FROM subscription_active WHERE profile_id=?", profile).Scan(&previous)
	if err != nil && err != sql.ErrNoRows {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO subscription_revisions(id,profile_id,state,codec,created,source_hash) VALUES(?,?,'staging',?,?,?)", revision, profile, CodecVersion, time.Now().UnixMilli(), sourceHash); err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO configuration_imports VALUES(?,?)", revision, os.Getpid()); err != nil {
		return "", err
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	completed := false
	defer func() {
		if !completed {
			s.DB.Exec("DELETE FROM subscription_revisions WHERE id=? AND state='staging'", revision)
		}
	}()
	header := *options
	header.Outbounds = nil
	header.Endpoints = nil
	header.RawMessage = nil
	if err = s.writeEntry(ctx, revision, Entry{ID: 0, Section: "root", Tag: "", Type: "root"}, header, Descriptor{}); err != nil {
		return "", err
	}
	nextID := int64(1)
	var batch *sql.Tx
	var batchCount int
	defer func() {
		if batch != nil {
			batch.Rollback()
		}
	}()
	write := func(entry Entry, value any, descriptor Descriptor) error {
		if batch == nil {
			var beginErr error
			batch, beginErr = s.DB.BeginTx(ctx, nil)
			if beginErr != nil {
				return beginErr
			}
		}
		if writeErr := s.writeEntryTx(ctx, batch, revision, entry, value, descriptor); writeErr != nil {
			return writeErr
		}
		batchCount++
		if batchCount >= 128 {
			if commitErr := batch.Commit(); commitErr != nil {
				return commitErr
			}
			batch = nil
			batchCount = 0
		}
		return nil
	}
	for i, out := range options.Outbounds {
		tag := out.Tag
		if tag == "" {
			tag = strconv.Itoa(i)
		}
		descriptor, ok := descriptors[tag]
		if !ok {
			return "", fmt.Errorf("missing validated outbound metadata")
		}
		entry := Entry{ID: nextID, Section: "outbounds", Ordinal: i, Tag: tag, Type: out.Type, Display: descriptor.Display, IsGroup: descriptor.IsGroup}
		if err = write(entry, out.Options, descriptor); err != nil {
			return "", err
		}
		nextID++
	}
	for i, end := range options.Endpoints {
		tag := end.Tag
		if tag == "" {
			tag = strconv.Itoa(i)
		}
		descriptor, ok := descriptors[tag]
		if !ok {
			return "", fmt.Errorf("missing validated endpoint metadata")
		}
		entry := Entry{ID: nextID, Section: "endpoints", Ordinal: i, Tag: tag, Type: end.Type, Display: descriptor.Display, IsGroup: descriptor.IsGroup}
		if err = write(entry, end.Options, descriptor); err != nil {
			return "", err
		}
		nextID++
	}
	if batch != nil {
		if err = batch.Commit(); err != nil {
			return "", err
		}
		batch = nil
	}
	tx, err = s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var now string
	scan := tx.QueryRowContext(ctx, "SELECT revision FROM subscription_active WHERE profile_id=?", profile).Scan(&now)
	if scan != nil && scan != sql.ErrNoRows {
		return "", scan
	}
	if now != previous {
		return "", fmt.Errorf("subscription changed during import")
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM configuration_imports WHERE revision=?", revision); err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE subscription_revisions SET state='ready' WHERE id=?", revision); err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO subscription_active(profile_id,revision) VALUES(?,?) ON CONFLICT(profile_id) DO UPDATE SET revision=excluded.revision", profile, revision); err != nil {
		return "", err
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	completed = true
	s.Cleanup(profile)
	return revision, nil
}

func (s *Store) writeEntry(ctx context.Context, revision string, entry Entry, value any, descriptor Descriptor) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = s.writeEntryTx(ctx, tx, revision, entry, value, descriptor); err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) writeEntryTx(ctx context.Context, tx *sql.Tx, revision string, entry Entry, value any, descriptor Descriptor) error {
	fields, err := s.codec.Encode(value)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO configuration_entries VALUES(?,?,?,?,?,?,?,?,?)", revision, entry.ID, entry.Section, entry.Ordinal, entry.Tag, entry.Type, entry.Display, entry.IsGroup, Fingerprint(fields)); err != nil {
		return err
	}
	statement, err := tx.PrepareContext(ctx, "INSERT INTO configuration_fields VALUES(?,?,?,?,?,?,?,?,?)")
	if err != nil {
		return err
	}
	defer statement.Close()
	for _, field := range fields {
		if _, err = statement.ExecContext(ctx, revision, entry.ID, field.Path, field.Kind, field.Type, field.Text, field.Number, field.Real, field.Bytes); err != nil {
			return err
		}
	}
	for i, network := range descriptor.Network {
		if _, err = tx.ExecContext(ctx, "INSERT INTO configuration_networks VALUES(?,?,?,?)", revision, entry.ID, i, network); err != nil {
			return err
		}
	}
	for i, tag := range descriptor.Dependencies {
		if _, err = tx.ExecContext(ctx, "INSERT INTO configuration_dependencies VALUES(?,?,?,?)", revision, entry.ID, i, tag); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) Resolve(ctx context.Context, profile, revision string) (string, error) {
	if revision == "" {
		if err := s.DB.QueryRowContext(ctx, "SELECT revision FROM subscription_active WHERE profile_id=?", profile).Scan(&revision); err != nil {
			return "", err
		}
	}
	var codec int
	var state string
	if err := s.DB.QueryRowContext(ctx, "SELECT codec,state FROM subscription_revisions WHERE id=? AND profile_id=?", revision, profile).Scan(&codec, &state); err != nil {
		return "", err
	}
	if codec != CodecVersion || state != "ready" {
		return "", fmt.Errorf("unsupported or incomplete database revision")
	}
	return revision, nil
}
func (s *Store) ReadFields(ctx context.Context, revision string, id int64, destination any) error {
	rows, err := s.DB.QueryContext(ctx, "SELECT path,kind,type_name,text_value,int_value,real_value,blob_value FROM configuration_fields WHERE revision=? AND entry_id=?", revision, id)
	if err != nil {
		return err
	}
	defer rows.Close()
	var fields []Field
	for rows.Next() {
		var field Field
		if err = rows.Scan(&field.Path, &field.Kind, &field.Type, &field.Text, &field.Number, &field.Real, &field.Bytes); err != nil {
			return err
		}
		fields = append(fields, field)
	}
	if err = rows.Err(); err != nil {
		return err
	}
	return s.codec.Decode(fields, destination)
}
func (s *Store) Entries(ctx context.Context, revision string) ([]Entry, error) {
	rows, err := s.DB.QueryContext(ctx, "SELECT id,section,ordinal,tag,type,display,is_group,fingerprint FROM configuration_entries WHERE revision=? AND section<>'root' ORDER BY section,ordinal", revision)
	if err != nil {
		return nil, err
	}
	var entries []Entry
	for rows.Next() {
		var entry Entry
		if err = rows.Scan(&entry.ID, &entry.Section, &entry.Ordinal, &entry.Tag, &entry.Type, &entry.Display, &entry.IsGroup, &entry.Fingerprint); err != nil {
			rows.Close()
			return nil, err
		}
		entries = append(entries, entry)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	byID := make(map[int64]*Entry, len(entries))
	for i := range entries {
		byID[entries[i].ID] = &entries[i]
	}
	networks, err := s.DB.QueryContext(ctx, "SELECT entry_id,network FROM configuration_networks WHERE revision=? ORDER BY entry_id,ordinal", revision)
	if err != nil {
		return nil, err
	}
	for networks.Next() {
		var id int64
		var network string
		if err = networks.Scan(&id, &network); err != nil {
			networks.Close()
			return nil, err
		}
		if entry := byID[id]; entry != nil {
			entry.Network = append(entry.Network, network)
		}
	}
	err = networks.Err()
	networks.Close()
	if err != nil {
		return nil, err
	}
	dependencies, err := s.DB.QueryContext(ctx, "SELECT entry_id,tag FROM configuration_dependencies WHERE revision=? ORDER BY entry_id,ordinal", revision)
	if err != nil {
		return nil, err
	}
	defer dependencies.Close()
	for dependencies.Next() {
		var id int64
		var tag string
		if err = dependencies.Scan(&id, &tag); err != nil {
			return nil, err
		}
		if entry := byID[id]; entry != nil {
			entry.Dependencies = append(entry.Dependencies, tag)
		}
	}
	return entries, dependencies.Err()
}

func (s *Store) ReadOptions(ctx context.Context, revision string, entry Entry) (any, error) {
	var value any
	var ok bool
	if entry.Section == "outbounds" {
		value, ok = service.FromContext[option.OutboundOptionsRegistry](s.context).CreateOptions(entry.Type)
	} else {
		value, ok = service.FromContext[option.EndpointOptionsRegistry](s.context).CreateOptions(entry.Type)
	}
	if !ok {
		return nil, fmt.Errorf("unknown database protocol %s", entry.Type)
	}
	if err := s.ReadFields(ctx, revision, entry.ID, value); err != nil {
		return nil, err
	}
	return value, nil
}

func SourceHash(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }

func databaseURL(scheme, path string) url.URL {
	path = filepath.ToSlash(path)
	if len(path) > 1 && path[1] == ':' {
		path = "/" + path
	}
	return url.URL{Scheme: scheme, Path: path}
}

func filesystemPath(path string) string {
	if len(path) > 2 && path[0] == '/' && path[2] == ':' {
		path = path[1:]
	}
	return filepath.FromSlash(path)
}
