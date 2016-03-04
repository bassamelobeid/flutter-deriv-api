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

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::AccessToken;
# use BOM::Database::ClientDB;
# use BOM::Database::Model::FinancialMarketBet::HigherLowerBet;
# use BOM::Database::Helper::FinancialMarketBet;
# use BOM::Database::DataMapper::FinancialMarketBet;

use utf8;

my ( $client, $client_token );
my ( $t, $rpc_ct );
my $method;

subtest 'Initialization' => sub {
    plan tests => 2;

    lives_ok {
        # my $connection_builder = BOM::Database::ClientDB->new({
        #     broker_code => 'CR',
        # });

        # $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        #     broker_code => 'CR',
        # });

        # my $account = $client->set_default_account('USD');
        # my %account_data = (account_data => {client_loginid => $account->client_loginid, currency_code => $account->currency_code});

        # $client->payment_free_gift(
        #     currency    => 'USD',
        #     amount      => 500,
        #     remark      => 'free gift',
        # );

        # my $start = DateTime->now()->subtract( DateTime::Duration->new( minutes     => 7 ) );
        # my $expire = $start->clone->add( DateTime::Duration->new( minutes     => 2 ) );

        # BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        #     short_code => 'CALL_frxUSDJPY_26.49_' . $start->epoch() . '_' . $expire->epoch() . '_S1P_S2P',
        #     type => 'fmb_higher_lower_call_buy',
        #     account_id => $account->id,
        #     buy_bet => 0,
        #     purchase_time => $start->strftime('%Y-%m-%d %H:%M:%S'),
        #     transaction_time => $start->strftime('%Y-%m-%d %H:%M:%S'),
        #     start_time => $start->strftime('%Y-%m-%d %H:%M:%S'),
        #     expiry_time => $expire->strftime('%Y-%m-%d %H:%M:%S'),
        #     settlement_time => $expire->strftime('%Y-%m-%d %H:%M:%S'),
        #     is_expired => 1,
        # });

        # my $mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        #     client_loginid => $client->loginid,
        #     currency_code  => 'USD',
        #     operation      => 'replica',
        # });

        my $m = BOM::Database::Model::AccessToken->new;

        $client_token = $m->create_token( 'CR0021', 'test token' );



        # TODO Почему этот токен не работает???
        # my $client_token = BOM::Platform::SessionCookie->new(
        #     loginid => "CR0021",
        #     email   => 'shuwnyuan@regentmarkets.com',
        # )->token;
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

    $params[1]->{sell_expired} = 1;

    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->result_is_deeply(
              { count => 0 },
              'It should return 0 if there was not expired contrancts' );
print Dumper $rpc_ct->result;




};

done_testing();