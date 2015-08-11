BEGIN;

-- Add new types to the bet dictionary
INSERT INTO bet.bet_dictionary (bet_type, path_dependent, table_name) VALUES ('DIGITOVER',  false, 'digit_bet');
INSERT INTO bet.bet_dictionary (bet_type, path_dependent, table_name) VALUES ('DIGITUNDER', false, 'digit_bet');
INSERT INTO bet.bet_dictionary (bet_type, path_dependent, table_name) VALUES ('DIGITODD',   false, 'digit_bet');
INSERT INTO bet.bet_dictionary (bet_type, path_dependent, table_name) VALUES ('DIGITEVEN',  false, 'digit_bet');

COMMIT;

-- Replace prediction constraint in two phases.

BEGIN; -- Phase one, update constraint without validation
ALTER TABLE ONLY bet.digit_bet DROP CONSTRAINT IF EXISTS chk_prediction_value;
ALTER TABLE ONLY bet.digit_bet
  ADD CONSTRAINT check_prediction_value
      CHECK (
             (prediction IN ('match',
                            'differ',
                            'over',
                            'under',
                            'odd',
                            'even')) IS TRUE
      ) NOT VALID;
COMMIT;

BEGIN; -- Phase two, ensure validation of old data
UPDATE pg_constraint
   SET convalidated=NOT EXISTS (
           SELECT *
             FROM bet.digit_bet
            WHERE NOT (
               (prediction IN ('match',
                              'differ',
                              'over',
                              'under',
                              'odd',
                              'even')) IS TRUE
        )
       )
WHERE NOT convalidated
 AND conrelid='bet.digit_bet'::REGCLASS::OID
 AND conname='check_prediction_value';
COMMIT;
