use strict;
use warnings;
use utf8;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::RPC::v3::Contract;
use BOM::RPC::v3::MarketDiscovery;
use BOM::Platform::Context qw (request);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Platform::RedisReplicated;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Database::Model::OAuth;
use Data::Dumper;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Quant::Framework::CorporateAction;
use Quant::Framework::StorageAccessor;
use Quant::Framework::Utils::Test;

my $storage_accessor = Quant::Framework::StorageAccessor->new(
    chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
    chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
);

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
$client->deposit_virtual_funds;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

#Create_doc for symbol USAAPL
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'EUR',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'USAAPL',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'USAAPL',
        recorded_date => Date::Utility->new,
    });

my $underlying = create_underlying('USAAPL');
my $date       = Date::Utility->new('2013-03-27');
my $opening    = $underlying->calendar->opening_on($underlying->exchange, $date);
my $starting   = $opening->plus_time_interval('50m');
my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'USAAPL',
    epoch      => $starting->epoch,
    quote      => 100
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'USAAPL',
    epoch      => $starting->epoch + 30,
    quote      => 111
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'USAAPL',
    epoch      => $starting->epoch + 90,
    quote      => 80
});

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
request(BOM::Platform::Context::Request->new(params => {}));

subtest 'get_corporate_actions' => sub {

    my $closing_time = $starting->plus_time_interval('1d')->truncate_to_day->plus_time_interval('23h59m59s');

    my $purchase_date = $date->epoch;

    my $params = {};

    $params->{args}{symbol} = 'USAAPL';
    $params->{args}{start}  = $opening->date_ddmmmyyyy;
    $params->{args}{end}    = $closing_time->date_ddmmmyyyy;

    #Create two corporate actions with same effective date.
    my $two_actions = {
        11223345 => {
            description    => 'Test corp act 1',
            action_code    => 3001,
            flag           => 'N',
            modifier       => 'divide',
            value          => 1.25,
            effective_date => $opening->plus_time_interval('1d')->date_ddmmmyy,
            type           => 'STOCK_SPLT',
        },
        11223346 => {
            description    => 'Test corp act 2',
            action_code    => 2000,
            flag           => 'N',
            modifier       => 'divide',
            value          => 2.25,
            effective_date => $opening->plus_time_interval('1d')->date_ddmmmyy,
            type           => 'DVD_STOCK',
        }};

    Quant::Framework::CorporateAction::create($storage_accessor, 'USAAPL', $starting)->update($two_actions, $starting)->save;

    my $result = $c->call_ok('get_corporate_actions', $params)->has_no_system_error->has_no_error->result;

    my $value = $result->{actions}[0]{value};

    cmp_ok $value, '==', 2.25, 'value for this  corporate action';

    my $modifier = $result->{actions}[0]{modifier};

    cmp_ok $modifier, 'eq', 'divide', 'modifier for this  corporate action';

    #Check value for the second corporate action.
    $value = $result->{actions}[1]{value};

    cmp_ok $value, '==', 1.25, 'value for the second corporate action';

    #Test for error case.
    my $params_err = {
        symbol => 'USAAPL',
        start  => $closing_time->date_ddmmmyyyy,
        end    => $opening->date_ddmmmyyyy,
    };

    $result = $c->call_ok('get_corporate_actions', $params_err)->has_error->error_code_is('GetCorporateActionsFailure')
        ->error_message_is('Sorry, an error occurred while processing your request.');

};

done_testing();

