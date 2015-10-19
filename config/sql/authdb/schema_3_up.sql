BEGIN;


CREATE TABLE auth.access_token (
    token           TEXT NOT NULL PRIMARY KEY,
    display_name    TEXT NOT NULL,
    client_loginid  TEXT NOT NULL,
    last_used       TIMESTAMP DEFAULT NULL
);
CREATE INDEX idx_access_token_client_loginid ON auth.access_token
 USING btree (client_loginid);

GRANT SELECT, INSERT, UPDATE, DELETE ON auth.access_token TO write;
GRANT SELECT ON auth.access_token TO read;

-- to have strong random numbers
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- The tokens generated here are slightly biased. The characters from
-- A to H have a slightly higher chance (+1/256) to appear in the token
-- than the rest. I think that's good enough.
CREATE OR REPLACE FUNCTION auth.generate_random_token(p_len INT)
RETURNS TEXT AS $$

WITH
arr(chrs) AS (
    SELECT ARRAY(SELECT chr(ascii('A')+i.i) FROM generate_series(0,25) i(i)
       UNION ALL SELECT chr(ascii('a')+i.i) FROM generate_series(0,25) i(i)
       UNION ALL SELECT chr(ascii('0')+i.i) FROM generate_series(0,9) i(i))
),
ac(c) AS (SELECT chrs||chrs||chrs||chrs||chrs FROM arr)

SELECT string_agg(ac.c[1 + get_byte(r.r,i.i)], '')
  FROM ac
 CROSS JOIN gen_random_bytes(p_len) r(r)
 CROSS JOIN generate_series(0,p_len-1) i(i)

$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION auth.create_token(p_tlen        INT,
                                             p_loginid     TEXT,
                                             p_displayname TEXT)
RETURNS TEXT AS $$

DECLARE
    t TEXT;
BEGIN
    LOOP
        BEGIN
            -- An INSERT locks the table automatically in ROW EXCLUSIVE mode
            -- which blocks concurrent modifications. Hence, no other locking
            -- is required.
            INSERT INTO auth.access_token(token, display_name, client_loginid)
            VALUES (auth.generate_random_token(p_tlen),
                    p_displayname, p_loginid)
            RETURNING token INTO t;
            RETURN t;
        EXCEPTION WHEN unique_violation THEN
            -- do nothing and continue with next loop
        END;
    END LOOP;
END;

$$ LANGUAGE plpgsql VOLATILE;


COMMIT;
