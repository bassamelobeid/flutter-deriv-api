use strict;
use warnings;
use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::RPC::v3::Contract;
use BOM::Platform::Context qw (request);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::System::RedisReplicated;
use BOM::Product::ContractFactory qw( produce_contract );
use Data::Dumper;

use Quant::Framework::CorporateAction;
use Quant::Framework::Utils::Test;

initialize_realtime_ticks_db();

my $now    = Date::Utility->new('2005-09-21 06:46:00');
my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
$client->deposit_virtual_funds;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $client->loginid,
    email   => $email
)->token;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD AUD CAD-AUD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw (frxAUDCAD frxUSDCAD frxAUDUSD);

#Create_doc for symbol FPFP
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'EUR',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'FPFP',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'FPFP',
        recorded_date => Date::Utility->new,
    });

my $date       = Date::Utility->new('2013-03-27');
my $opening    = BOM::Market::Underlying->new('FPFP')->exchange->opening_on($date);
my $underlying = BOM::Market::Underlying->new('FPFP');
my $starting   = $underlying->exchange->opening_on(Date::Utility->new('2013-03-27'))->plus_time_interval('50m');
my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'FPFP',
    epoch      => $starting->epoch,
    quote      => 100
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'FPFP',
    epoch      => $starting->epoch + 30,
    quote      => 111
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'FPFP',
    epoch      => $starting->epoch + 90,
    quote      => 80
});

###

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
request(BOM::Platform::Context::Request->new(params => {l => 'ZH_CN'}));

subtest 'get_corporate_actions' => sub {

    #Create corporate actions
    my $one_action = {
        11223344 => {
            description    => 'Test corp act 1',
            flag           => 'U',
            modifier       => 'divide',
            value          => 1.25,
            effective_date => $opening->plus_time_interval('1d')->date_ddmmmyy,
            type           => 'DVD_STOCK',
        }};

    Quant::Framework::Utils::Test::create_doc(
        'corporate_action',
        {
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            actions          => $one_action,
        });

    #create bet params for the corp act
    my $closing_time = $starting->plus_time_interval('1d')->truncate_to_day->plus_time_interval('23h59m59s');
    my $bet_params   = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        duration     => '1d',
        barrier      => 'S0P',
        entry_tick   => $entry_tick,
        date_pricing => $closing_time,
    };
    my $contract = produce_contract($bet_params);

    my $purchase_date = $date->epoch;

    #Create new transactions.
    my $txn = BOM::Product::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => 100,
        payout        => $contract->payout,
        amount_type   => 'stake',
        purchase_date => $purchase_date,
    });

    my $expiry = $contract->date_expiry->truncate_to_day;

    my $params = {
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    $params = {language => 'ZH_CN'};

    my $result = $c->call_ok('get_corporate_actions', $params)->has_no_system_error->has_no_error->result;

    my @expected_keys = (
        qw(contract_id
            underlying
            is_valid_to_sell
            date_start
            date_expiry
            date_settlement
            currency
            longcode
            shortcode
            contract_type
            ));
    is_deeply([sort keys %{$result}], [sort @expected_keys]);

};

done_testing();

