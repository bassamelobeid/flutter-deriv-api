use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use Test::BOM::RPC::Client;

use utf8;

my ( $t, $rpc_ct );
my $method = 'contracts_for';

my @params = (
    $method,
    {
        language => 'RU',
        source => 1,
        country => 'ru',
        args => {
            contracts_for => 'R_50',
        },
    }
);

$t = Test::Mojo->new('BOM::RPC');
$rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );

subtest "Request $method" => sub {
    my %got_landing_company;

    $rpc_ct->call_ok(@params)
            ->has_no_system_error
            ->has_no_error;

    is_deeply   [sort keys %{ $rpc_ct->result }],
                [sort qw/ available close open hit_count spot feed_license /],
                'It should return contracts_for object';
    ok @{ $rpc_ct->result->{available} }, 'It should return available contracts';
    %got_landing_company = map { $_->{landing_company} => 1 } @{ $rpc_ct->result->{available} };
    is_deeply   [keys %got_landing_company],
                [qw/ costarica /],
                'It should return available contracts only for costarica region';

    $params[1]{args}{region} = 'japan';
    $params[1]{args}{contracts_for} = 'frxUSDJPY';
    $rpc_ct->call_ok(@params)
            ->has_no_system_error
            ->has_no_error;

    is_deeply   [sort keys %{ $rpc_ct->result }],
                [sort qw/ available close open hit_count spot feed_license /],
                'It should return contracts_for object for japan region';
    ok @{ $rpc_ct->result->{available} }, 'It should return available contracts only for japan region';
    %got_landing_company = map { $_->{landing_company} => 1 } @{ $rpc_ct->result->{available} };
    is_deeply   [keys %got_landing_company],
                [qw/ japan /],
                'It should return available contracts only for japan region';

    $params[1]{args}{contracts_for} = 'invalid symbol';
    $rpc_ct->call_ok(@params)
            ->has_no_system_error
            ->has_error
            ->error_code_is('InvalidSymbol', 'It should return error if symbol does not exist')
            ->error_message_is('Неверный символ.', 'It should return error if symbol does not exist');
};

done_testing();
