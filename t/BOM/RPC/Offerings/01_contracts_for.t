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

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );
    } 'Initial RPC server and client connection';
};

subtest "Request $method" => sub {
    $rpc_ct->call_ok(@params)
            ->has_no_system_error
            ->has_no_error;

    is_deeply   [sort keys %{ $rpc_ct->result }],
                [sort qw/ available close open hit_count spot feed_license /],
                'It should return contracts_for object';
    ok @{ $rpc_ct->result->{available} }, 'It should return available contracts';

    $params[1]{args}{region} = 'japan';
    $rpc_ct->call_ok(@params)
            ->has_no_system_error
            ->has_no_error;

    is_deeply   [sort keys %{ $rpc_ct->result }],
                [sort qw/ available close open hit_count spot feed_license /],
                'It should return contracts_for object for japan region';
    ok @{ $rpc_ct->result->{available} }, 'It should return available contracts for japan region';

    $params[1]{args}{contracts_for} = 'invalid symbol';
    $rpc_ct->call_ok(@params)
            ->has_no_system_error
            ->has_error
            ->error_code_is('InvalidSymbol', 'It should return error if symbol does not exist')
            ->error_message_is('Неверный символ.', 'It should return error if symbol does not exist');
};

done_testing();
