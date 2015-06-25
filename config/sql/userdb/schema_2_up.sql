BEGIN;

SET search_path = users;

CREATE TABLE IF NOT EXISTS failed_login (
    id bigint NOT NULL PRIMARY KEY,
    last_attempt timestamp without time zone NOT NULL,
    fail_count smallint NOT NULL,
    CONSTRAINT positive_fail_count CHECK ((fail_count > 0)),
    CONSTRAINT fk_failed_login_email FOREIGN KEY (id) REFERENCES binary_user(id)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON users.failed_login TO write;
GRANT SELECT ON users.failed_login TO read;

COMMIT;
