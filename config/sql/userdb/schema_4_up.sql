CREATE INDEX CONCURRENTLY loginid_user_id_idx ON users.loginid USING btree (binary_user_id);
CREATE INDEX CONCURRENTLY login_history_user_id_idx ON users.login_history USING btree (binary_user_id);

ALTER TABLE users.binary_user DROP CONSTRAINT IF EXISTS binary_user_email_key;

CREATE INDEX CONCURRENTLY user_email_idx ON users.binary_user USING btree (email);
CREATE UNIQUE INDEX CONCURRENTLY user_unique_email ON users.binary_user USING btree (lower((email)::text));
