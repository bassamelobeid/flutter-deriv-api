#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Warnings;
use Test::Exception;
use Guard;
use Crypt::NamedKeys;
use BOM::User::Client;
use BOM::User::Password;
use BOM::Config::Runtime;

use BOM::CompanyLimits::Limits;

use Date::Utility;
use Math::Util::CalculatedValue::Validatable;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Time qw( sleep_till_next_second );
use BOM::Test::Contract;
use BOM::Config::RedisReplicated;

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $redis = BOM::Config::RedisReplicated::redis_limits_write;

sub setup_tests {
    $redis->flushall(); # cleanup past data
    $redis->hmset('CONTRACTGROUPS',   ('CALL', 'CALLPUT'));
    $redis->hmset('UNDERLYINGGROUPS', ('R_50', 'volidx'));
}

subtest 'buy a bet', sub {
    plan tests => 2;
    setup_tests();
    my $cl = create_client;
    top_up $cl, 'USD', 5000;
    BOM::CompanyLimits::Limits::add_limit('POTENTIAL_LOSS', 'R_50,,,', 100, 0, 0);
    my $contract = BOM::Test::Contract::create_contract(
        payout        => 1000,
        underlying    => 'R_50',
        purchase_date => Date::Utility->new('2019-12-01'),
    );

    my ($trx, $fmb) = BOM::Test::Contract::buy_contract(
        client   => $cl,
        contract => $contract,
    );

    BOM::Test::Contract::sell_contract(
        client       => $cl,
        contract_id  => $fmb->{id},
        contract     => $contract,
        sell_outcome => 1,
    );
};

done_testing;
