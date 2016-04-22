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

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
request(BOM::Platform::Context::Request->new(params => {l => 'ZH_CN'}));

subtest 'get_corporate_actions_one_action' => sub {

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

    my $closing_time = $starting->plus_time_interval('1d')->truncate_to_day->plus_time_interval('23h59m59s');

    my $purchase_date = $date->epoch;

    my $params = {
        language => 'ZH_CN',
        symbol   => 'FPFP',
        start    => $opening->date_ddmmmyyyy,
        end      => $closing_time->date_ddmmmyyyy,
    };

    my $result = $c->call_ok('get_corporate_actions', $params)->has_no_system_error->has_no_error->result;

    my @expected_keys = (qw(28-Mar-2013));

    is_deeply([sort keys %{$result}], [sort @expected_keys]);

    my $value = $result->{'28-Mar-2013'}->{value};

    cmp_ok $value, '==', 1.25, 'value for this  corporate action';

    #Test for error case.
    my $params_err = {
        language => 'ZH_CN',
        symbol   => 'FPFP',
        start    => $closing_time->date_ddmmmyyyy,
        end      => $opening->date_ddmmmyyyy,
    };

    $result = $c->call_ok('get_corporate_actions', $params_err)->has_error->error_code_is('GetCorporateActionsFailure')->error_message_is('');

};

done_testing();

