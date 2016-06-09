#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;

use Test::NoWarnings ();    # no END block test
use Test::Exception;
#use BOM::Database::Helper::FinancialMarketBet;
#use BOM::Platform::Client;
use BOM::Database::ClientDB;
#use BOM::System::Password;
#use BOM::Platform::Client::Utility;
#use BOM::Database::Model::FinancialMarketBet::Factory;
#use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
#Crypt::NamedKeys->keyfile('/etc/rmg/aes_keys.yml');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

subtest 'check daily_aggregates' => sub {

    is(db->dbh->selectrow_hashref(qq{
        SELECT
            count(*) as cnt
        FROM (
            SELECT
                c.loginid,
                a.id,
                turnover7, loss7, turnover30, loss30,
                fmb7.turnover AS old_turnover7, fmb7.loss AS old_loss7,
                fmb30.turnover AS old_turnover30, fmb30.loss AS old_loss30
            FROM
                a.client AS c
                JOIN transaction.account AS a ON (a.client_loginid = c.loginid)
                FULL JOIN (
                    SELECT account_id, sum(CASE WHEN  date_trunc('day', now()) - '6d'::INTERVAL <= day AND day < date_trunc('day', now()) + '1d'::INTERVAL THEN turnover ELSE 0 END) AS turnover7,sum(CASE WHEN  date_trunc('day', now()) - '6d'::INTERVAL <= day AND day < date_trunc('day', now()) + '1d'::INTERVAL THEN loss ELSE 0 END) AS loss7, sum(CASE WHEN  date_trunc('day', now()) - '29d'::INTERVAL <= day AND day < date_trunc('day', now()) + '1d'::INTERVAL THEN turnover ELSE 0 END) AS turnover30,sum(CASE WHEN  date_trunc('day', now()) - '29d'::INTERVAL <= day AND day < date_trunc('day', now()) + '1d'::INTERVAL THEN loss ELSE 0 END) AS loss30
                    FROM bet.daily_aggregates
                    GROUP BY 1
                ) AS agg
                    ON (agg.account_id = a.id)
                FULL JOIN (
                    SELECT
                        b.account_id,
                        coalesce(sum(b.buy_price), 0) AS turnover,
                        coalesce(sum(b.buy_price - b.sell_price), 0) AS loss
                    FROM bet.financial_market_bet b
                    WHERE date_trunc('day', now()) - '29d'::INTERVAL <= b.purchase_time
                       AND b.purchase_time < date_trunc('day', now()) + '1d'::INTERVAL
                    GROUP BY 1
                ) AS fmb30
                    ON (fmb30.account_id = a.id)
                FULL JOIN (
                    SELECT
                        b.account_id,
                        coalesce(sum(b.buy_price), 0) AS turnover,
                        coalesce(sum(b.buy_price - b.sell_price), 0) AS loss
                    FROM bet.financial_market_bet b
                    WHERE date_trunc('day', now()) - '6d'::INTERVAL <= b.purchase_time
                       AND b.purchase_time < date_trunc('day', now()) + '1d'::INTERVAL
                    GROUP BY 1
                ) AS fmb7
                    ON (fmb7.account_id = account.id)
        ) AS res
        WHERE
            turnover7 IS DISTINCT FROM old_turnover7
            OR loss7 IS DISTINCT FROM old_loss7
            OR turnover30 IS DISTINCT FROM old_turnover30
            OR loss30 IS DISTINCT FROM old_loss30
    })->{'cnt'}, 0, "No difference between daily_aggregate and agg select");


};

Test::NoWarnings::had_no_warnings;

done_testing;
