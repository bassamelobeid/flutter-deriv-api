BEGIN;

ALTER TABLE data_collection.quants_bet_variables
    ADD COLUMN entry_spot numeric,
    ADD COLUMN entry_spot_epoch numeric,
    ADD COLUMN exit_spot numeric,
    ADD COLUMN exit_spot_epoch numeric,
    ADD COLUMN hit_spot numeric,
    ADD COLUMN hit_spot_epoch numeric;

COMMIT;
