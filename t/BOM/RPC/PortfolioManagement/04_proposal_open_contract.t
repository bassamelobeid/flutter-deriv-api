use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use DateTime;

use Test::BOM::RPC::Client;

use BOM::Market::Data::DatabaseAPI;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Database::Model::AccessToken;
use BOM::Database::ClientDB;

use utf8;

my ( $client, $client_token, $session );
my ( $t, $rpc_ct );
my $method = 'proposal_open_contract';

my @params = (
    $method,
    {
        language => 'RU',
        source => 1,
        country => 'ru',
        args => {},
    }
);

subtest 'Initialization' => sub {
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client->payment_free_gift(
            currency    => 'USD',
            amount      => 500,
            remark      => 'free gift',
        );

        my $m = BOM::Database::Model::AccessToken->new;

        $client_token = $m->create_token( $client->loginid, 'test token' );

        $session = BOM::Platform::SessionCookie->new(
            loginid => $client->loginid,
            email   => $client->email,
        )->token;
    } 'Initial clients';

    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );
    } 'Initial RPC server';
};

subtest 'Auth client' => sub {
    $rpc_ct->call_ok(@params)
           ->has_no_system_error
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
           ->has_no_system_error
           ->result_is_deeply(
                {
                    error => {
                        message_to_client => 'Токен недействителен.',
                        code => 'InvalidToken',
                    }
                },
                'It should return error: InvalidToken' );

    delete $params[1]->{token};
    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->result_is_deeply(
                {
                    error => {
                        message_to_client => 'Токен недействителен.',
                        code => 'InvalidToken',
                    }
                },
                'It should return error: InvalidToken' );

    $params[1]->{token} = $client_token;

    {
        my $module = Test::MockModule->new('BOM::Platform::Client');
        $module->mock( 'new', sub {} );

        $rpc_ct->call_ok(@params)
              ->has_no_system_error
              ->has_error
              ->error_code_is( 'AuthorizationRequired', 'It should check auth' );
    }

    $rpc_ct->call_ok(@params)
          ->has_no_system_error
          ->has_no_error('It should be success using token');

    $params[1]->{token} = $session;

    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->has_no_error('It should be success using session');
};



done_testing();

sub create_contract {
    my ( $client, %params ) = @_;

    my $account = $client->set_default_account('USD');
    return BOM::Test::Data::Utility::UnitTestDatabase::create_valid_contract({
        type               => 'fmb_higher_lower_call_buy',
        short_code_prefix  => 'CALL_R_100_26.49',
        short_code_postfix => 'S0P_0',
        account_id         => $account->id,
        buy_bet            => 0,
        %params,
    });
}