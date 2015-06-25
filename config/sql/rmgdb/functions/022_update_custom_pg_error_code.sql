BEGIN;

CREATE TABLE IF NOT EXISTS betonmarkets.custom_pg_error_codes (
    code        TEXT PRIMARY KEY,
    explanation TEXT
);
GRANT SELECT ON betonmarkets.custom_pg_error_codes TO SELECT_on_betonmarkets;


CREATE OR REPLACE FUNCTION betonmarkets.update_custom_pg_error_code(
    p_code        TEXT,
    p_explanation TEXT
) RETURNS betonmarkets.custom_pg_error_codes
AS $def$

    WITH upd AS (
        UPDATE betonmarkets.custom_pg_error_codes t
           SET explanation=p_explanation
         WHERE t.code=p_code
        RETURNING *
    )
    INSERT INTO betonmarkets.custom_pg_error_codes(code, explanation)
    SELECT * FROM (VALUES (p_code, p_explanation)) dat(code, explanation)
     WHERE NOT EXISTS (SELECT * FROM upd);

    SELECT * FROM betonmarkets.custom_pg_error_codes
     WHERE code=p_code;

$def$ LANGUAGE sql VOLATILE SECURITY invoker;

COMMIT;
