PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS subscription_revisions(id TEXT PRIMARY KEY,profile_id TEXT NOT NULL,state TEXT NOT NULL,codec INTEGER NOT NULL,created INTEGER NOT NULL,source_hash TEXT NOT NULL DEFAULT '');
 CREATE TABLE IF NOT EXISTS configuration_imports(revision TEXT PRIMARY KEY REFERENCES subscription_revisions(id) ON DELETE CASCADE,owner_pid INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS subscription_active(profile_id TEXT PRIMARY KEY,revision TEXT NOT NULL REFERENCES subscription_revisions(id));
 CREATE TABLE IF NOT EXISTS configuration_entries(revision TEXT NOT NULL REFERENCES subscription_revisions(id) ON DELETE CASCADE,id INTEGER NOT NULL,section TEXT NOT NULL,ordinal INTEGER NOT NULL,tag TEXT NOT NULL,type TEXT NOT NULL,display TEXT NOT NULL,is_group INTEGER NOT NULL,fingerprint TEXT NOT NULL,PRIMARY KEY(revision,id),UNIQUE(revision,tag));
 CREATE INDEX IF NOT EXISTS configurations_name ON configuration_entries(revision,is_group DESC,tag,id);
 CREATE TABLE IF NOT EXISTS configuration_fields(revision TEXT NOT NULL,entry_id INTEGER NOT NULL,path TEXT NOT NULL,kind TEXT NOT NULL,type_name TEXT NOT NULL,text_value TEXT NOT NULL,int_value INTEGER NOT NULL,real_value REAL NOT NULL,blob_value BLOB,PRIMARY KEY(revision,entry_id,path),FOREIGN KEY(revision,entry_id) REFERENCES configuration_entries(revision,id) ON DELETE CASCADE) WITHOUT ROWID;
 CREATE TABLE IF NOT EXISTS configuration_networks(revision TEXT NOT NULL,entry_id INTEGER NOT NULL,ordinal INTEGER NOT NULL,network TEXT NOT NULL,PRIMARY KEY(revision,entry_id,ordinal),FOREIGN KEY(revision,entry_id) REFERENCES configuration_entries(revision,id) ON DELETE CASCADE);
 CREATE TABLE IF NOT EXISTS configuration_dependencies(revision TEXT NOT NULL,entry_id INTEGER NOT NULL,ordinal INTEGER NOT NULL,tag TEXT NOT NULL,PRIMARY KEY(revision,entry_id,ordinal),FOREIGN KEY(revision,entry_id) REFERENCES configuration_entries(revision,id) ON DELETE CASCADE);
 CREATE TABLE IF NOT EXISTS configuration_status(revision TEXT NOT NULL,entry_id INTEGER NOT NULL,session TEXT NOT NULL,network_epoch INTEGER NOT NULL,sequence INTEGER NOT NULL,delay INTEGER NOT NULL,unavailable INTEGER NOT NULL,checked INTEGER NOT NULL,PRIMARY KEY(revision,entry_id),FOREIGN KEY(revision,entry_id) REFERENCES configuration_entries(revision,id) ON DELETE CASCADE);
 CREATE TABLE IF NOT EXISTS configuration_usage(revision TEXT NOT NULL,entry_id INTEGER NOT NULL,session TEXT NOT NULL,upload INTEGER NOT NULL,download INTEGER NOT NULL,PRIMARY KEY(revision,entry_id),FOREIGN KEY(revision,entry_id) REFERENCES configuration_entries(revision,id) ON DELETE CASCADE);
 CREATE TABLE IF NOT EXISTS configuration_runtime(profile_id TEXT PRIMARY KEY,revision TEXT NOT NULL,session TEXT NOT NULL,updated INTEGER NOT NULL,network_epoch INTEGER NOT NULL DEFAULT 0);
 CREATE TABLE IF NOT EXISTS configuration_selections(profile_id TEXT NOT NULL,group_tag TEXT NOT NULL,tag TEXT NOT NULL,PRIMARY KEY(profile_id,group_tag));
 CREATE TABLE IF NOT EXISTS configuration_revision_leases(token TEXT PRIMARY KEY,revision TEXT NOT NULL REFERENCES subscription_revisions(id),owner_pid INTEGER NOT NULL,created INTEGER NOT NULL);
 CREATE TRIGGER IF NOT EXISTS release_deleted_revision AFTER DELETE ON configuration_revision_leases
 BEGIN
 DELETE FROM subscription_revisions WHERE id=OLD.revision AND state='deleted' AND NOT EXISTS(SELECT 1 FROM configuration_revision_leases WHERE revision=OLD.revision);
 END;
 CREATE TABLE IF NOT EXISTS application_options(id TEXT PRIMARY KEY,state TEXT NOT NULL,representation TEXT NOT NULL,created INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS application_option_fields(version TEXT NOT NULL REFERENCES application_options(id) ON DELETE CASCADE,path TEXT NOT NULL,kind TEXT NOT NULL,type_name TEXT NOT NULL,text_value TEXT NOT NULL,int_value INTEGER NOT NULL,real_value REAL NOT NULL,blob_value BLOB,PRIMARY KEY(version,path)) WITHOUT ROWID;
 PRAGMA user_version=1;
