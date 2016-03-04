use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use FindBin;
use lib "$FindBin::Bin/../../lib";
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use DateTime;

use Test::BOM::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Database::Model::AccessToken;
use BOM::Database::ClientDB;
use BOM::Database::Model::FinancialMarketBet::HigherLowerBet;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Database::DataMapper::FinancialMarketBet;

use utf8;

my ( $client, $client_token, $session, $account );
my ( $t, $rpc_ct );
my $method = 'sell_expired';

subtest 'Initialization' => sub {
    plan tests => 2;

    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $account = $client->set_default_account('USD');

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
    } "Initial account";

    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
    } 'Initial RPC server';
};

my @params = (
    $method,
    {
        language => 'RU',
        source => 1,
        country => 'ru',
        args => { sell_expired => 1 },
    }
);

$rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );
subtest 'Auth' => sub {
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

    $params[1]->{token} = undef;
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

subtest 'Initialization contract' => sub {
    plan tests => 1;

    lives_ok {
        my $start = DateTime->now()->subtract( minutes => 7 );
        my $expire = $start->clone->add( DateTime::Duration->new( minutes     => 2 ) );

        for my $epoch ( $start->epoch .. $expire->epoch ) {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch      => $epoch,
                underlying => 'R_100',
            });
        }

        my $short_code = 'CALL_R_100_26.49_'
                       . $start->epoch() . '_'
                       . $expire->epoch()
                       . '_S0P_0';

        BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
            short_code => $short_code,
            type => 'fmb_higher_lower_call_buy',
            account_id => $account->id,
            purchase_time => $start->strftime('%Y-%m-%d %H:%M:%S'),
            transaction_time => $start->strftime('%Y-%m-%d %H:%M:%S'),
            start_time => $start->strftime('%Y-%m-%d %H:%M:%S'),
            expiry_time => $expire->strftime('%Y-%m-%d %H:%M:%S'),
            settlement_time => $expire->strftime('%Y-%m-%d %H:%M:%S'),
            is_expired => 1,
            buy_bet => 0,
        });

        BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $client->loginid,
            currency_code  => 'USD',
            operation      => 'replica',
        });
    } 'Create expired contract for sell';
};

subtest 'Sell expired contracts' => sub {
    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->has_no_error
           ->result_is_deeply(
              { count => 1 },
              'It should return counts of sold contrancts' );

};

done_testing();