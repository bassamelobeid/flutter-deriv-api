#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Warnings;
use Test::Exception;

use BOM::CompanyLimits::Limits;

use Date::Utility;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Time qw( sleep_till_next_second );
use BOM::Test::Contract qw(create_contract buy_contract sell_contract);
use BOM::Config::RedisReplicated;

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $redis = BOM::Config::RedisReplicated::redis_limits_write;

sub setup_tests {
    $redis->flushall();    # cleanup past data
    $redis->hmset('CONTRACTGROUPS',   ('CALL', 'CALLPUT'));
    $redis->hmset('UNDERLYINGGROUPS', ('R_50', 'volidx'));
}

subtest 'Limits test base case', sub {
    plan tests => 2;
    setup_tests();
    my $cl = create_client;
    top_up $cl, 'USD', 5000;

    # Apply a potential loss limit on a single underlying, then buy 2 contracts;
    # second one will trigger limit breach.
    BOM::CompanyLimits::Limits::add_limit('POTENTIAL_LOSS', 'R_50,,,', 10, 0, 0);

    my ($contract, $trx, $fmb, $total);

    $contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
    );

    ($trx, $fmb) = buy_contract(
        client    => $cl,
        buy_price => 2,
        contract  => $contract,
    );

    $total = $redis->hget('TOTALS_POTENTIAL_LOSS', 'R_50,,,');
    cmp_ok $total, '==', 4;

    # same contract, but we crank up the price hundred fold to exceed limit
    $contract = create_contract(
        payout     => 600,
        underlying => 'R_50',
    );

    dies_ok {
        ($trx, $fmb) = buy_contract(
            client    => $cl,
            buy_price => 200,
            contract  => $contract,
        );
    }, 'limit exceeded! Should throw some descriptive error';

    # sell_contract(
    #     client       => $cl,
    #     contract_id  => $fmb->{id},
    #     contract     => $contract,
    #     sell_outcome => 1,
    # );
};

done_testing;
