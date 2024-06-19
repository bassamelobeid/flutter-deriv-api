package BOM::Backoffice::Script::CopyTradingStatistics;
use strict;
use warnings;

use BOM::User::Client;
use BOM::Config::Redis;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;

sub run {
# Exponential moving average
# The coefficient "k" represents the degree of weighting decrease,
# a constant smoothing factor between 0 and 1. A higher "k" discounts older observations faster.
    my $k = 0.3;

    my $trader_ids = BOM::Database::ClientDB->new({
            broker_code => 'CR',
            operation   => 'backoffice_replica',
        }
    )->db->dbic->run(
        fixup => sub {
            $_->selectcol_arrayref(
                q{
        SELECT
            loginid
        FROM
            betonmarkets.client
        WHERE
            allow_copiers IS TRUE
    }
            );
        });

    for my $trader_id (@$trader_ids) {
        my $last_processed_id = BOM::Config::Redis::redis_replicated_read()->get("COPY_TRADING_LAST_PROCESSED_ID:$trader_id") || 0;
        my $max_processed_id  = $last_processed_id;

        my $trader = BOM::User::Client->new({loginid => $trader_id});
        my $txn_dm = BOM::Database::DataMapper::Transaction->new({
            client_loginid => $trader->loginid,
            currency_code  => $trader->default_account->currency_code,
            broker_code    => 'CR',
            operation      => 'backoffice_replica'
        });
        my $unsold_bets      = BOM::Config::Redis::redis_replicated_read()->smembers("COPY_TRADING_UNSOLD_BETS:$trader_id");
        my $unprocessed_bets = $txn_dm->unprocessed_bets($last_processed_id, $unsold_bets);

        for my $bet (@$unprocessed_bets) {
            my ($id, $is_sold, $underlying_symbol, $duration, $profit, $profitable) = @$bet;

            unless ($is_sold) {
                BOM::Config::Redis::redis_replicated_write()->sadd("COPY_TRADING_UNSOLD_BETS:$trader_id", $id);
                next;
            }

            my $avg_duration = BOM::Config::Redis::redis_replicated_read()->get("COPY_TRADING_AVG_DURATION:$trader_id") || $duration;
            $avg_duration = $k * $duration + (1 - $k) * $avg_duration;
            BOM::Config::Redis::redis_replicated_write()->set("COPY_TRADING_AVG_DURATION:$trader_id", $avg_duration);

            BOM::Config::Redis::redis_replicated_write()->hincrby("COPY_TRADING_SYMBOLS_BREAKDOWN:$trader_id", $underlying_symbol, 1);

            BOM::Config::Redis::redis_replicated_write()->incr("COPY_TRADING_PROFITABLE:$trader_id:$profitable");

            my $avg_profit = BOM::Config::Redis::redis_replicated_read()->get("COPY_TRADING_AVG_PROFIT:$trader_id:$profitable") || $profit;
            $avg_profit = $k * $profit + (1 - $k) * $avg_profit;
            BOM::Config::Redis::redis_replicated_write()->set("COPY_TRADING_AVG_PROFIT:$trader_id:$profitable", $avg_profit);

            $max_processed_id = $id if $id > $max_processed_id;
            BOM::Config::Redis::redis_replicated_write()->srem("COPY_TRADING_UNSOLD_BETS:$trader_id", $id);
        }
        BOM::Config::Redis::redis_replicated_write()->set("COPY_TRADING_LAST_PROCESSED_ID:$trader_id", $max_processed_id) if $max_processed_id;
    }
    return 0;
}

1;
