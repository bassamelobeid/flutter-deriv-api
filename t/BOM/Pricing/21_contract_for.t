use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use Date::Utility;
use BOM::Test::RPC::Client;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods update_predefined_highlow);

use utf8;

my $now = Date::Utility->new('2016-03-18 00:00:00');
set_absolute_time($now->epoch);
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->minus_time_interval('100d')->epoch,
});
diag("100d is " . $now->minus_time_interval('100d')->yyyymmdd);
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                                                         underlying => 'frxUSDJPY',
                                                         epoch      => $now->minus_time_interval('99d')->epoch,
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

$t = Test::Mojo->new('BOM::Pricing::RPC');
$rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);

subtest "Request $method" => sub {
    my (%got_landing_company, $result);

    $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;

    is_deeply [sort keys %{$result}], [sort qw/ available close open hit_count spot feed_license /], 'It should return contracts_for object';
    ok @{$result->{available}}, 'It should return available contracts';
    ok !grep { $_->{contract_type} =~ /^(EXPIRYMISS|EXPIRYRANGE)E$/ } @{$result->{available}};

    generate_trading_periods('frxUSDJPY');
    update_predefined_highlow({
        symbol => 'frxUSDJPY',
        price  => 100,
        epoch  => time
    });
    $params[1]{args}{product_type}  = 'multi_barrier';
    $params[1]{args}{contracts_for} = 'frxUSDJPY';
    $result                         = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    is_deeply [sort keys %{$result}],
        [sort qw/ available close open hit_count spot feed_license /],
        'It should return contracts_for object for japan region';
    ok @{$result->{available}}, 'It should return available contracts only for japan region';
    ok !grep { $_->{contract_type} =~ /^(CALL|PUTE|EXPIRYMISSE|EXPIRYRANGE)$/ } @{$result->{available}};

    $params[1]{args}{contracts_for} = 'invalid symbol';
    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if symbol does not exist')
        ->error_message_is('The symbol is invalid.', 'It should return error if symbol does not exist');
};

done_testing();
