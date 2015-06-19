BEGIN;

SET search_path = users;

CREATE TABLE IF NOT EXISTS login_history (
    id BIGSERIAL NOT NULL PRIMARY KEY,
    binary_user_id BIGINT NOT NULL,
    action VARCHAR(15) NOT NULL,
    history_date TIMESTAMP(0) without time zone DEFAULT now(),
    environment VARCHAR(1024) NOT NULL,
    successful BOOLEAN NOT NULL,
    CONSTRAINT fk_login_history_user_id FOREIGN KEY (binary_user_id) REFERENCES binary_user(id) ON UPDATE CASCADE ON DELETE RESTRICT
);

GRANT SELECT, INSERT, UPDATE ON users.login_history TO write;
GRANT SELECT ON users.login_history TO read;
GRANT USAGE ON users.login_history_id_seq TO write;

COMMIT;
