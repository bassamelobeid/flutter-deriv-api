use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use FindBin;
use lib "$FindBin::Bin/../../lib";
use MojoX::JSON::RPC::Client;
use Data::Dumper;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Database::Model::AccessToken;

use utf8;

my ( $client, $client_token );
my $method;
my ( $t, $rpc_ct );

subtest 'Initialization' => sub {
    plan tests => 2;

    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        my $m = BOM::Database::Model::AccessToken->new;

        $client_token = $m->create_token( $client->loginid, 'test token' );

        # $client_account = $client->set_default_account('USD');

        # $client->payment_free_gift(
        #     currency => 'USD',
        #     amount   => 5000,
        #     remark   => 'free gift',
        # );
    } 'Initial accounts to test portfolio';

    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
    } 'Initial RPC server to test portfolio methods';
};

$rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );
$method = 'sell_expired';
subtest "$method method" => sub {
    my @params = ( $method, { language => 'RU' } );

    $rpc_ct->call_ok(@params)
           ->has_no_error
           ->result_is_deeply(
                {
                    error => {
                        message_to_client => 'Токен недействителен.',
                        code => 'InvalidToken',
                    }
                },
                'It should return error: InvalidToken' );

    $params[1]->{token} = 'wrong token';
    $rpc_ct->call_ok(@params)
           ->has_no_error
           ->result_is_deeply(
                {
                    error => {
                        message_to_client => 'Токен недействителен.',
                        code => 'InvalidToken',
                    }
                },
                'It should return error: InvalidToken' );

    $params[1]->{token} = undef;
    $rpc_ct->call_ok(@params)
           ->has_no_error
           ->result_is_deeply(
                {
                    error => {
                        message_to_client => 'Токен недействителен.',
                        code => 'InvalidToken',
                    }
                },
                'It should return error: InvalidToken' );

    $params[1]->{token} = $client_token;
    $rpc_ct->call_ok(@params)
           ->has_no_error
           ->result_is_deeply(
              { count => 0 },
              'Auth with client token should be ok' );



};

done_testing();