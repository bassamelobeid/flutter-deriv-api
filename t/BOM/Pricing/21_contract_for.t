use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use Date::Utility;
use BOM::Test::RPC::Client;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods);

use utf8;

my $mock = Test::MockModule->new('BOM::Product::Contract::PredefinedParameters');
$mock->mock('_get_predefined_highlow', sub { (100, 90) });
set_absolute_time(Date::Utility->new('2016-03-18 00:15:00')->epoch);
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => Date::Utility->new->minus_time_interval('100d')->epoch,
});

my ($t, $rpc_ct);
my $method = 'contracts_for';

my @params = (
    $method,
    {
        language => 'EN',
        country  => 'ru',
        args     => {
            contracts_for => 'R_50',
        },
    });

$t      = Test::Mojo->new('BOM::RPC::Transport::HTTP');
$rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);

subtest "Request $method" => sub {
    my (%got_landing_company, $result);

    $params[1]{args}{currency} = 'INVALID';
    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_error->error_code_is('InvalidCurrency', 'It should return correct error code if currency is invalid')
        ->error_message_is('The provided currency INVALID is invalid.', 'It should return correct error message if currency is invalid');

    $params[1]{args}{currency} = 'USD';
    $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;

    is_deeply [sort keys %{$result}], [sort qw/ available close open hit_count spot feed_license stash/], 'It should return contracts_for object';
    ok @{$result->{available}}, 'It should return available contracts';
    ok !grep { $_->{contract_type} =~ /^(EXPIRYMISS|EXPIRYRANGE)E$/ } @{$result->{available}};

    # check for multiplier related config
    my @multiplier = grep { $_->{contract_category} eq 'multiplier' } @{$result->{available}};
    ok @multiplier, 'has multiplier';
    ok $multiplier[0]->{multiplier_range},   'has multiplier range';
    ok $multiplier[0]->{cancellation_range}, 'has cancellation range';

    BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods('frxUSDJPY', Date::Utility->new);
    $params[1]{args}{product_type}  = 'multi_barrier';
    $params[1]{args}{contracts_for} = 'frxUSDJPY';
    $result                         = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    is_deeply [sort keys %{$result}],
        [sort qw/ available close open hit_count spot feed_license stash/],
        'It should return contracts_for object for multi_barrier contracts';
    ok @{$result->{available}}, 'It should return available multi_barrier contracts';
    ok !grep { $_->{contract_type} =~ /^(CALL|PUTE|EXPIRYMISSE|EXPIRYRANGE)$/ } @{$result->{available}};

    $params[1]{args}{contracts_for} = 'invalid symbol';
    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if symbol does not exist')
        ->error_message_is('This contract is not offered in your country.', 'It should return error if symbol does not exist');

    delete $params[1]{args}{product_type};
    $params[1]{args}{landing_company} = 'maltainvest';
    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if offering is unavailable')
        ->error_message_is('This contract is not offered in your country.', 'It should return error if offering is unavailable');
};

done_testing();
