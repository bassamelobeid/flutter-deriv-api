BEGIN;

-- TABLE: oauth.access_token, oauth.user_scope_confirm
-- drop FK
ALTER TABLE oauth.access_token          DROP CONSTRAINT access_token_app_id_fkey;
ALTER TABLE oauth.user_scope_confirm    DROP CONSTRAINT user_scope_confirm_app_id_fkey;
ALTER TABLE oauth.user_scope_confirm    DROP CONSTRAINT pkey_oauth_user_scope_confirm;

-- rename column
ALTER TABLE oauth.access_token          RENAME COLUMN app_id TO __app_id;
ALTER TABLE oauth.user_scope_confirm    RENAME COLUMN app_id TO __app_id;

-- new app_id column
ALTER TABLE oauth.access_token          ADD COLUMN app_id BIGINT;
ALTER TABLE oauth.user_scope_confirm    ADD COLUMN app_id BIGINT;


-- TABLE: oauth.apps
ALTER TABLE oauth.apps                  DROP CONSTRAINT apps_pkey;
ALTER TABLE oauth.apps                  RENAME COLUMN id TO __id;

-- new id field
CREATE SEQUENCE oauth.apps_id_seq
     START WITH 1000
     INCREMENT BY 1
     MINVALUE 1000
     NO MAXVALUE
     CACHE 1;
ALTER TABLE oauth.apps ADD COLUMN id BIGINT DEFAULT nextval('oauth.apps_id_seq'::regclass) NOT NULL PRIMARY KEY;

GRANT USAGE ON oauth.apps_id_seq TO postgres;
GRANT USAGE ON oauth.apps_id_seq TO write;
GRANT USAGE ON oauth.apps_id_seq TO read;

-- binarycom app
UPDATE oauth.apps   SET id = 1 WHERE __id = 'binarycom';
UPDATE oauth.apps   SET id = 2 WHERE __id = 'id-ct9oK1jjUNyxvPKYNdqJxuGX7bHvJ';
UPDATE oauth.apps   SET id = 3 WHERE __id = 'id-evoGhPBCXfJTRnPcTmJ1yaGGOyD0B';
UPDATE oauth.apps   SET id = 4 WHERE __id = 'id-5vndA78d0CUwdZIY8QjmS3fafV8G6';
UPDATE oauth.apps   SET id = 5 WHERE __id = 'id-OWBASFFrGSqAAJwXohVbQbK2k2ZIf';
UPDATE oauth.apps   SET id = 6 WHERE __id = 'id-vVa9bwUYEFCiMkErZrKvMGtzVMWvZ';
UPDATE oauth.apps   SET id = 7 WHERE __id = 'id-avVHmHHAwfUfAFI7wojJE6ZtTc7S2';
UPDATE oauth.apps   SET id = 8 WHERE __id = 'id-uWvVBcUiVeClE42Z6yupP6enXU283';
UPDATE oauth.apps   SET id = 9 WHERE __id = 'id-h0WqKf4FUjukc4R9KKNTjPHBJ2hbW';
UPDATE oauth.apps   SET id = 10 WHERE __id = 'id-OKJY118FaKoGMouqLVSpR0aTcEIgc';
UPDATE oauth.apps   SET id = 11 WHERE __id = 'id-U9w4wlBvwakOOo6qlurAdzlhMM9ec';
UPDATE oauth.apps   SET id = 12 WHERE __id = 'id-dCQvoX4iE6mnCrmVzNTpohV4w6UfJ';
UPDATE oauth.apps   SET id = 13 WHERE __id = 'id-vN7ig1HDXJGLS6ymSvnStPioHyytG';
UPDATE oauth.apps   SET id = 14 WHERE __id = 'id-Vb4N24n2Kbki6M6QqLUAbY7YzhtgE';
UPDATE oauth.apps   SET id = 15 WHERE __id = 'id-Fyc42BtrzzFm2zNsdqYupfRHw2Uai';
UPDATE oauth.apps   SET id = 16 WHERE __id = 'id-feDSSnPS7FurZ6vVaSdapN8TMApmI';
UPDATE oauth.apps   SET id = 17 WHERE __id = 'id-vK8W8BBkjqYOeBqFNPoGp0GtBfeCr';
UPDATE oauth.apps   SET id = 18 WHERE __id = 'id-sbFB3ptvRVHaPUQX6WBrpAMYnUx0X';
UPDATE oauth.apps   SET id = 19 WHERE __id = 'id-MztUdUzmvv6D82jX3kTIV6YQZKNoH';
UPDATE oauth.apps   SET id = 20 WHERE __id = 'id-im6XumYsBXJwsgBE7GdPVJOxzokLM';
UPDATE oauth.apps   SET id = 21 WHERE __id = 'id-M7WpSJwvGlUbPHGzVeXGUiqLsldd4';
UPDATE oauth.apps   SET id = 22 WHERE __id = 'id-8jsvu4KlqAIWe7QfMdooxI1MysKN5';
UPDATE oauth.apps   SET id = 23 WHERE __id = 'id-qTwlgHJRdPhSoVlLr0xZSukpBzGZX';
UPDATE oauth.apps   SET id = 24 WHERE __id = 'id-Gi4cqASC9Lj5BriayCJ1IMiZIr6M1';
UPDATE oauth.apps   SET id = 25 WHERE __id = 'id-UuhLUU58MBvWoVvuueGOFpvuZxy9w';
UPDATE oauth.apps   SET id = 26 WHERE __id = 'id-UzqwL5EoykkQfT2oe8W58XiqSkMVj';
UPDATE oauth.apps   SET id = 27 WHERE __id = 'id-0NfVVJOTjP7MwibaLUp2mxT1NOBd6';
UPDATE oauth.apps   SET id = 28 WHERE __id = 'id-9TOwkNEqEsJNL59sorlquaLcAP5zS';
UPDATE oauth.apps   SET id = 29 WHERE __id = 'id-Cqt0tCagVnEqY4bBm27S1MUKXsKpu';
UPDATE oauth.apps   SET id = 30 WHERE __id = 'id-8S86TbDrMuYAiKVztuHc4T22uPsXw';
UPDATE oauth.apps   SET id = 31 WHERE __id = 'id-4Dif6suvu6raAPQM1J61g8RMfIaGw';
UPDATE oauth.apps   SET id = 32 WHERE __id = 'id-ks8ZtIN7CHzdh9DRdCxWYROqfbsUp';
UPDATE oauth.apps   SET id = 33 WHERE __id = 'id-2oiodQsKqKmVekhsCdF60FKwKIYt4';
UPDATE oauth.apps   SET id = 34 WHERE __id = 'id-FwnhrVstk9kPBnDfocVpk8ZDtNs1V';
UPDATE oauth.apps   SET id = 35 WHERE __id = 'id-lzNzcmvdgbB99jBFl3IGO3yLgmUSK';
UPDATE oauth.apps   SET id = 36 WHERE __id = 'id-EmcupPkdLUKfScM8vsM6Hc4httJrL';
UPDATE oauth.apps   SET id = 37 WHERE __id = 'id-yfBPXh3678sX8W1q6xDvr71pk1VJK';
UPDATE oauth.apps   SET id = 38 WHERE __id = 'binary-expiryd';


-- populate app_id
UPDATE oauth.access_token               SET app_id = a.id FROM oauth.apps a WHERE __app_id = a.__id;
UPDATE oauth.user_scope_confirm         SET app_id = a.id FROM oauth.apps a WHERE __app_id = a.__id;

-- FK
ALTER TABLE oauth.access_token          ADD CONSTRAINT access_token_app_id_fkey         FOREIGN KEY (app_id) REFERENCES oauth.apps (id);
ALTER TABLE oauth.user_scope_confirm    ADD CONSTRAINT user_scope_confirm_app_id_fkey   FOREIGN KEY (app_id) REFERENCES oauth.apps (id);
ALTER TABLE oauth.user_scope_confirm    ADD PRIMARY KEY (app_id, loginid);

-- DROP old column
ALTER TABLE oauth.access_token          DROP COLUMN __app_id;
ALTER TABLE oauth.user_scope_confirm    DROP COLUMN __app_id;
ALTER TABLE oauth.apps                  DROP COLUMN __id;

COMMIT;
