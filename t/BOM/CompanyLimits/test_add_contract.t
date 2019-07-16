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
use BOM::Transaction;
use BOM::Transaction::Validation;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Time qw( sleep_till_next_second );
use BOM::Platform::Client::IDAuthentication;
use BOM::Config::RedisReplicated;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

sub _clean_redis {
    BOM::Config::RedisReplicated::redis_limits_write->flushall();
}

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(validate_tnc          => sub { note "mocked Transaction::Validation->validate_tnc returning nothing";          undef });
$mock_validation->mock(compliance_checks     => sub { note "mocked Transaction::Validation->compliance_checks returning nothing";     undef });
$mock_validation->mock(check_tax_information => sub { note "mocked Transaction::Validation->check_tax_information returning nothing"; undef });

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for qw(JPY USD JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });

my $old_tick1 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 99,
    underlying => 'R_50',
    quote      => 76.5996,
    bid        => 76.6010,
    ask        => 76.2030,
});

my $old_tick2 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 52,
    underlying => 'R_50',
    quote      => 76.6996,
    bid        => 76.7010,
    ask        => 76.3030,
});

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

my $usdjpy_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

my $tick_r100 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_100',
    quote      => 100,
});

# Spread is calculated base on spot of the underlying.
# In this case, we mocked the spot to 100.
my $mocked_underlying = Test::MockModule->new('Quant::Framework::Underlying');
$mocked_underlying->mock('spot', sub { 100 });

my $underlying      = create_underlying('R_50');
my $underlying_r100 = create_underlying('R_100');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

my $cl;
my $acc_usd;
my $acc_aud;

####################################################################
# real tests begin here
####################################################################

lives_ok {
    $cl = create_client;
    top_up $cl, 'USD', 5000;
}
'client created and funded';

my ($trx, $fmb, $chld, $qv1, $qv2);

my $new_client = create_client;
top_up $new_client, 'USD', 5000;
my $new_acc_usd = $new_client->account;

sub setup_groups {
    BOM::Config::RedisReplicated::redis_limits_write->hmset('CONTRACTGROUPS', ('CALL', 'CALLPUT'));
    BOM::Config::RedisReplicated::redis_limits_write->hmset('UNDERLYINGGROUPS', ('R_50', 'volidx'));
}

subtest 'buy a bet', sub {
    plan tests => 2;
    _clean_redis();
    setup_groups();
    BOM::CompanyLimits::Limits::add_limit('POTENTIAL_LOSS', 'R_50,,,', 100, 0, 0);
    lives_ok {
        my $contract = produce_contract({
                underlying => $underlying,
                bet_type   => 'CALL',
                currency   => 'USD',
                payout     => 1000,
                duration   => '15m',
                current_tick => $tick,
                barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 514.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            source        => 19,
            purchase_date => $contract->date_start,
        });
        my $error = $txn->buy;
        is $error, undef, 'no error';
    }, 'survived';
};


$mocked_underlying->unmock_all;

done_testing;
