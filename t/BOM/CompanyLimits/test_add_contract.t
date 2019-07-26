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

subtest 'buy a bet', sub {
    plan tests => 2;
    setup_tests();
    my $cl = create_client;
    top_up $cl, 'USD', 5000;
    BOM::CompanyLimits::Limits::add_limit('POTENTIAL_LOSS', 'R_50,,,', 100, 0, 0);
    my $contract = create_contract(
        payout     => 1000,
        underlying => 'R_50',
        # duration      => '15m',
        purchase_date => Date::Utility->new('2019-12-01'),
    );

    my ($trx, $fmb) = buy_contract(
        client    => $cl,
        buy_price => 400,
        contract  => $contract,
    );

    sell_contract(
        client       => $cl,
        contract_id  => $fmb->{id},
        contract     => $contract,
        sell_outcome => 1,
    );
};

done_testing;
