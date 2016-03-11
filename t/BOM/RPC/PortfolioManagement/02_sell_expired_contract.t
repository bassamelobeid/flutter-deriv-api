use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use RateLimitations qw(within_rate_limits);

use Test::BOM::RPC::Client;

use BOM::Market::Data::DatabaseAPI;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Database::Model::AccessToken;
use BOM::Database::ClientDB;

use utf8;

my ( $vclient, $vclient_token,
     $client, $client_token, $session );
my ( $t, $rpc_ct );
my $method = 'sell_expired';

my @params = (
    $method,
    {
        language => 'RU',
        source => 1,
        country => 'ru',
        args => { sell_expired => 1 },
    }
);

subtest 'Initialization' => sub {
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $vclient = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });

        $client->payment_free_gift(
            currency    => 'USD',
            amount      => 500,
            remark      => 'free gift',
        );

        my $m = BOM::Database::Model::AccessToken->new;

        $client_token = $m->create_token( $client->loginid, 'test token' );
        $vclient_token = $m->create_token( $vclient->loginid, 'test token' );

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

subtest 'Sell expired contract' => sub {
    lives_ok {
        create_fmb( $client, is_expired => 1 );
    } 'Create expired contract for sell';

    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->has_no_error
           ->result_is_deeply(
              { count => 1 },
              'It should return counts of sold contracts' );

    lives_ok {
        create_fmb( $client );
    } 'Create expired contract for sell';

    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->has_no_error
           ->result_is_deeply(
              { count => 0 },
              'It should return 0 if there are not expired contracts' );
};

subtest 'Emergency error while sell contract' => sub {
    my $module = Test::MockModule->new('BOM::Product::Transaction');
    $module->mock( 'sell_expired_contracts', sub { die } );

    $rpc_ct->call_ok(@params)
           ->has_error
           ->error_code_is('SellExpiredError');
};

subtest 'Sell virtual client expired contract' => sub {
    $params[1]->{token} = $vclient_token;

    lives_ok {
        create_fmb( $vclient, is_expired => 1 );
    } 'Create expired contract for sell';

    {
        my $module = Test::MockModule->new('BOM::Product::Contract');
        $module->mock( 'is_valid_to_sell', sub {} );

        $rpc_ct->call_ok(@params)
               ->has_no_system_error
               ->has_no_error
               ->result_is_deeply(
                  { count => 1 },
                  'if cannot settle bet due to missing market data, sell contract with buy price' );
    }

    lives_ok {
        create_fmb( $vclient, is_expired => 1 );
    } 'Create expired contract for sell';

    for (0..8) {
        ok within_rate_limits({
            service  => 'virtual_batch_sell',
            consumer => $vclient->loginid
        }), 'Virtual client has no lookup';
    } # 9 times because we had one from previous test
    ok !within_rate_limits({
            service  => 'virtual_batch_sell',
            consumer => $vclient->loginid
        }), 'Virtual client has reached 10 lookups in one min';

    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->has_no_error
           ->result_is_deeply(
              { count => 0 },
              'Apply rate limits before doing the full lookup' );
};

done_testing();

sub create_fmb {
    my ( $client, %params ) = @_;

    my $account = $client->set_default_account('USD');
    return BOM::Test::Data::Utility::UnitTestDatabase::create_fmb_with_ticks({
        %params,
        type               => 'fmb_higher_lower_call_buy',
        short_code_prefix  => 'CALL_R_100_26.49',
        short_code_postfix => 'S0P_0',
        account_id         => $account->id,
        buy_bet            => 0,
    });
}