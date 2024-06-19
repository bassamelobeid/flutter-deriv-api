use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::Warn;
use MojoX::JSON::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase   qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Platform::Token::API;
use BOM::Database::ClientDB;
use BOM::Database::Model::OAuth;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Email::Stuffer::TestLinks;
use JSON::MaybeUTF8 qw(:v1);

use utf8;

my ($client, $client_token, $oauth_token);
my $rpc_ct;
my $method = 'proposal_open_contract';

my @params = (
    $method,
    {
        language => 'EN',
        country  => 'ru',
        args     => {},
    });

$rpc_ct = BOM::Test::RPC::QueueClient->new();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

initialize_realtime_ticks_db();

subtest 'Initialization' => sub {
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client->payment_free_gift(
            currency => 'USD',
            amount   => 500,
            remark   => 'free gift',
        );

        my $m = BOM::Platform::Token::API->new;

        $client_token = $m->create_token($client->loginid, 'test token');

        ($oauth_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    }
    'Initial clients';
};

subtest 'Auth client' => sub {
    $rpc_ct->call_ok(@params)->has_no_system_error->result_is_deeply({
            error => {
                message_to_client => 'The token is invalid.',
                code              => 'InvalidToken',
            }
        },
        'It should return error: InvalidToken'
    );

    $params[1]->{token} = 'wrong token';
    $rpc_ct->call_ok(@params)->has_no_system_error->result_is_deeply({
            error => {
                message_to_client => 'The token is invalid.',
                code              => 'InvalidToken',
            }
        },
        'It should return error: InvalidToken'
    );

    delete $params[1]->{token};
    $rpc_ct->call_ok(@params)->has_no_system_error->result_is_deeply({
            error => {
                message_to_client => 'The token is invalid.',
                code              => 'InvalidToken',
            }
        },
        'It should return error: InvalidToken'
    );

    $params[1]->{token} = $client_token;

    {
        my $module = Test::MockModule->new('BOM::User::Client');
        $module->mock('new', sub { });

        $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'It should check auth');
    }

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('It should be success using token');

    $params[1]->{token} = $oauth_token;

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('It should be success using oauth token');
};

subtest 'poc language setting' => sub {
    my @params1 = (
        $method,
        {
            language => 'ES',
            country  => 'ru',
            args     => {subscribe => 1},
        });

    lives_ok {
        create_fmb($client, buy_bet => 1);
    }
    'Create contract';
    $params1[1]->{token} = $oauth_token;
    my $result = $rpc_ct->call_ok(@params1)->has_no_system_error->has_no_error->result;

    my $pricer_keys = $result->{pricer_args_keys}->[0];
    $pricer_keys =~ s/^PRICER_ARGS:://;
    my $payload                     = decode_json_utf8($pricer_keys);
    my $params                      = {@{$payload}};
    my $poc_parameters_redis_pricer = BOM::Pricing::v3::Utility::get_poc_parameters($params->{contract_id}, $params->{landing_company});
    is $poc_parameters_redis_pricer->{language}, 'ES', 'Langage set correctly for poc subscription parameter';
};

done_testing();

sub create_fmb {
    my ($client, %params) = @_;

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
