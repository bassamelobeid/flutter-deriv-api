BEGIN;

INSERT INTO oauth.scopes (scope) VALUES ('admin');
INSERT INTO oauth.scopes (scope) VALUES ('payments');
DELETE FROM oauth.scopes WHERE scope IN ('cashier');

COMMIT;