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
use BOM::Test::RPC::QueueClient;

use utf8;

set_absolute_time(Date::Utility->new('2016-03-18 00:15:00')->epoch);
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => Date::Utility->new->minus_time_interval('100d')->epoch,
});

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

my $rpc_ct = BOM::Test::RPC::QueueClient->new();

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

};

done_testing();
