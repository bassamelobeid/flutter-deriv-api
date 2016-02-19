BEGIN;

INSERT into bet.bet_dictionary
    (bet_type, path_dependent, table_name) values ('PUTE', false, 'higher_lower_bet');

INSERT into bet.bet_dictionary
    (bet_type, path_dependent, table_name) values ('CALLE', false, 'higher_lower_bet');

INSERT into bet.bet_dictionary
    (bet_type, path_dependent, table_name) values ('EXPIRYMISSE', false, 'range_bet');

INSERT into bet.bet_dictionary
    (bet_type, path_dependent, table_name) values ('EXPIRYRANGEE', false, 'range_bet');
COMMIT;
