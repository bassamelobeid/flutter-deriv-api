BEGIN;

INSERT INTO oauth.scopes (scope) VALUES ('read');
INSERT INTO oauth.scopes (scope) VALUES ('admin');
INSERT INTO oauth.scopes (scope) VALUES ('payments');

UPDATE oauth.user_scope_confirm
SET scope_id = (SELECT id FROM oauth.scopes WHERE scope='read')
WHERE scope_id = (SELECT id FROM oauth.scopes WHERE scope='user');

UPDATE oauth.auth_code_scope
SET scope_id = (SELECT id FROM oauth.scopes WHERE scope='read')
WHERE scope_id = (SELECT id FROM oauth.scopes WHERE scope='user');

UPDATE oauth.access_token_scope
SET scope_id = (SELECT id FROM oauth.scopes WHERE scope='read')
WHERE scope_id = (SELECT id FROM oauth.scopes WHERE scope='user');

UPDATE oauth.refresh_token_scope
SET scope_id = (SELECT id FROM oauth.scopes WHERE scope='read')
WHERE scope_id = (SELECT id FROM oauth.scopes WHERE scope='user');

DELETE FROM oauth.scopes WHERE scope IN ('cashier', 'user');

CREATE TABLE auth.scopes (
    id SERIAL PRIMARY KEY,
    scope VARCHAR( 100 ) NOT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.scopes TO write;
GRANT SELECT ON auth.scopes TO read;

INSERT INTO auth.scopes (scope) VALUES ('read');
INSERT INTO auth.scopes (scope) VALUES ('trade');
INSERT INTO auth.scopes (scope) VALUES ('admin');
INSERT INTO auth.scopes (scope) VALUES ('payments');

CREATE TABLE auth.access_token_scope (
    access_token         char(16) NOT NULL,
    scope_id             INTEGER NOT NULL REFERENCES auth.scopes(id)
);
CREATE INDEX idx_auth_access_token_scope_access_token ON auth.access_token_scope USING btree (access_token);
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.access_token_scope TO write;
GRANT SELECT ON auth.access_token_scope TO read;

COMMIT;