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

$t = Test::Mojo->new('BOM::RPC');
$rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );

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

subtest $method => sub {
    my $fmb;
    my $contract_id;
    my @expected_contract_fields;

    lives_ok {
        $fmb = create_fmb ( $client, buy_bet => 1 )->financial_market_bet_record;
    } 'Initial bet';

    $rpc_ct->call_ok(@params)
            ->has_no_system_error
            ->has_no_error;
    lives_ok {
        my $bid = BOM::RPC::v3::Contract::get_bid({
            short_code  => $fmb->{short_code},
            contract_id => $fmb->{id},
            currency    => $client->currency,
            is_sold     => $fmb->{is_sold},
        });

        @expected_contract_fields = qw/ buy_price purchase_time account_id is_sold /;
        push @expected_contract_fields, keys %$bid;
    } 'Get extected data';
    is_deeply(
        [ sort keys %{ $rpc_ct->result->{ $fmb->{id} } } ],
        [ sort @expected_contract_fields ],
        'Should return contract and bid data' );

    $params[1]->{contract_id} = $fmb->{id};
    $rpc_ct->call_ok(@params)
            ->has_no_system_error
            ->has_no_error;
    lives_ok {
        my $bid = BOM::RPC::v3::Contract::get_bid({
            short_code  => $fmb->{short_code},
            contract_id => $fmb->{id},
            currency    => $client->currency,
            is_sold     => $fmb->{is_sold},
        });

        @expected_contract_fields = qw/ buy_price purchase_time account_id is_sold /;
        push @expected_contract_fields, keys %$bid;
    } 'Get extected data';
    is_deeply(
        [ sort keys %{ $rpc_ct->result->{ $fmb->{id} } } ],
        [ sort @expected_contract_fields ],
        'Should return contract and bid data by contract_id' );

    my $contract_factory = Test::MockModule->new('BOM::RPC::v3::Contract');
    $contract_factory->mock('produce_contract', sub { die });

    $rpc_ct->call_ok(@params)
            ->has_no_system_error
            ->result_is_deeply(
                {
                    $fmb->{id} => {
                        error => {
                            message_to_client => 'Извините, при обработке Вашего запроса произошла ошибка.',
                            code => 'GetProposalFailure',
                        },
                    },
                },
                'Should return error instead contract data',
            );
};

done_testing();

sub create_fmb {
    my ( $client, %params ) = @_;

    my $account = $client->set_default_account('USD');
    return BOM::Test::Data::Utility::UnitTestDatabase::create_fmb_with_ticks({
        type               => 'fmb_higher_lower_call_buy',
        short_code_prefix  => 'CALL_R_100_26.49',
        short_code_postfix => 'S0P_0',
        account_id         => $account->id,
        buy_bet            => 0,
        %params,
    });
}
