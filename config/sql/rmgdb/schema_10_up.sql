BEGIN;

ALTER TABLE bet.digit_bet DROP CONSTRAINT IF EXISTS chk_prediction_value;
ALTER TABLE bet.digit_bet ADD CONSTRAINT chk_prediction_value CHECK (((prediction)::text = ANY ((ARRAY['match'::character varying, 'differ'::character varying, 'over'::character varying, 'under'::character varying, 'odd'::character varying, 'even'::character varying])::text[])));

INSERT INTO bet.bet_dictionary (bet_type, path_dependent, table_name) VALUES ('DIGITOVER',  false, 'digit_bet');
INSERT INTO bet.bet_dictionary (bet_type, path_dependent, table_name) VALUES ('DIGITUNDER', false, 'digit_bet');
INSERT INTO bet.bet_dictionary (bet_type, path_dependent, table_name) VALUES ('DIGITODD',   false, 'digit_bet');
INSERT INTO bet.bet_dictionary (bet_type, path_dependent, table_name) VALUES ('DIGITEVEN',  false, 'digit_bet');

COMMIT;
