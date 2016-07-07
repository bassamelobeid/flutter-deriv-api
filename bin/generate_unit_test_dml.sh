#!/bin/bash

# reset_rmgdb.sh <<<mRX1E3Mi00oS8LG

pw="$(head -1)"

perl -MBOM::Test::Data::Utility::UnitTestDatabase=:init -e1

(
PGHOST=localhost PGPORT=5432 \
  PGDATABASE=regentmarkets \
  PGUSER=postgres PGPASSWORD="$pw" \
pg_dump -w regentmarkets -a \
    -t audit.db_activity \
    -t betonmarkets.broker_code \
    -t betonmarkets.client \
    -t transaction.account \
    -t bet.financial_market_bet \
    -t bet.higher_lower_bet \
    -t bet.legacy_bet \
    -t bet.range_bet \
    -t bet.run_bet \
    -t bet.touch_bet \
    -t betonmarkets.client_authentication_document \
    -t betonmarkets.client_authentication_method \
    -t betonmarkets.promo_code \
    -t betonmarkets.client_promo_code \
    -t betonmarkets.client_status \
    -t betonmarkets.payment_agent \
    -t betonmarkets.self_exclusion \
    -t data_collection.exchange_rate \
    -t payment.payment \
    -t transaction.transaction \
    -t payment.affiliate_reward \
    -t payment.bank_wire \
    -t payment.doughflow \
    -t payment.free_gift \
    -t payment.legacy_payment

PGHOST=localhost PGPORT=5432 \
  PGDATABASE=regentmarkets \
  PGUSER=postgres PGPASSWORD="$pw" \
pg_dump -w regentmarkets -a | grep pg_catalog.setval

echo "DELETE FROM data_collection.exchange_rate WHERE id < 1099;"
) > /home/git/regentmarkets/bom-postgres-clientdb/config/sql/unit_test_dml.sql
