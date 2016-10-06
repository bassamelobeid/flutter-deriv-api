#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 1;
use Test::Exception;
use BOM::Database::ClientDB;

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

subtest 'check daily_aggregates' => sub {

    my $res = db->dbh->selectrow_hashref(
        qq{
        SELECT
            count(*) as cnt,
            sum(
                CASE
                    WHEN (
                        turnover7 IS DISTINCT FROM old_turnover7
                        OR loss7 IS DISTINCT FROM old_loss7
                        OR turnover30 IS DISTINCT FROM old_turnover30
                        OR loss30 IS DISTINCT FROM old_loss30
                    ) THEN
                        1
                    ELSE
                        0
                    END
            ) AS unequal
        FROM (
            SELECT
                c.loginid,
                a.id,
                turnover7, loss7, turnover30, loss30,
                fmb7.turnover AS old_turnover7, fmb7.loss AS old_loss7,
                fmb30.turnover AS old_turnover30, fmb30.loss AS old_loss30
            FROM
                betonmarkets.client AS c
                JOIN transaction.account AS a ON (a.client_loginid = c.loginid)
                FULL JOIN (
                    WITH trange AS (
                        SELECT
                            'today'::timestamp - '6d'::INTERVAL AS last6,
                            'today'::timestamp - '29d'::INTERVAL AS last29,
                            'tomorrow'::timestamp AS tomorrow
                    ) SELECT
                        account_id,
                        sum(CASE WHEN trange.last6 <= day AND day < trange.tomorrow THEN turnover END) AS turnover7,
                        sum(CASE WHEN trange.last6 <= day AND day < trange.tomorrow THEN loss END) AS loss7,
                        sum(CASE WHEN trange.last29 <= day AND day < trange.tomorrow THEN turnover END) AS turnover30,
                        sum(CASE WHEN trange.last29 <= day AND day < trange.tomorrow THEN loss END) AS loss30
                    FROM bet.daily_aggregates, trange
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
                    ON (fmb7.account_id = a.id)
        ) AS res
    }
    );

    isnt($res->{cnt}, 0, "No rows in daily_aggregate and agg select");
    is($res->{unequal}, 0, "No difference between daily_aggregate and agg select");

};

done_testing;
