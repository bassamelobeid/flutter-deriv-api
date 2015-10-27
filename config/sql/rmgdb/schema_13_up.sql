BEGIN;

SET search_path = sequences, pg_catalog;

CREATE SEQUENCE loginid_sequence_vrtj
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 1000
    NO MAXVALUE
    CACHE 1;

CREATE SEQUENCE loginid_sequence_jp
    START WITH 1000
    INCREMENT BY 1
    MINVALUE 1000
    NO MAXVALUE
    CACHE 1;

GRANT ALL ON SEQUENCE sequences.loginid_sequence_vrtj to write;
GRANT ALL ON SEQUENCE sequences.loginid_sequence_jp to write;

COMMIT;
