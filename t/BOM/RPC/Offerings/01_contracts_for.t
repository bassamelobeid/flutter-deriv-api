use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use Date::Utility;
use Test::BOM::RPC::Client;

use utf8;
set_absolute_time(Date::Utility->new('2016-03-18 00:00:00')->epoch);
my ($t, $rpc_ct);
my $method = 'contracts_for';

my @params = (
    $method,
    {
        language => 'RU',
        source   => 1,
        country  => 'ru',
        args     => {
            contracts_for => 'R_50',
        },
    });

$t = Test::Mojo->new('BOM::RPC');
$rpc_ct = Test::BOM::RPC::Client->new(ua => $t->app->ua);

subtest "Request $method" => sub {
    my (%got_landing_company, $result);

    $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;

    is_deeply [sort keys %{$result}], [sort qw/ available close open hit_count spot feed_license /], 'It should return contracts_for object';
    ok @{$result->{available}}, 'It should return available contracts';
    ok !grep {$_->{contract_type} =~ /^(CALL|PUT|EXPIRYMISS|EXPIRYRANGE)E$/} @{$result->{available}};

    $params[1]{args}{region}        = 'japan';
    $params[1]{args}{contracts_for} = 'frxUSDJPY';
    $result                         = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;

    is_deeply [sort keys %{$result}],
        [sort qw/ available close open hit_count spot feed_license /],
        'It should return contracts_for object for japan region';
    ok @{$result->{available}}, 'It should return available contracts only for japan region';
    ok !grep {$_->{contract_type} =~ /^(CALL|PUT|EXPIRYMISS|EXPIRYRANGE)$/} @{$result->{available}};

    $params[1]{args}{contracts_for} = 'invalid symbol';
    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if symbol does not exist')
        ->error_message_is('Неверный символ.', 'It should return error if symbol does not exist');
};

done_testing();
