use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use BOM::Test::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Database::Model::AccessToken;
use BOM::Database::ClientDB;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;

use utf8;

my ($client, $client_token, $oauth_token);
my ($t, $rpc_ct);
my $method = 'portfolio';

my @params = (
    $method,
    {
        language => 'EN',
        source   => 1,
        country  => 'ru',
    });

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

        my $m = BOM::Database::Model::AccessToken->new;
        $client_token = $m->create_token($client->loginid, 'test token');

        ($oauth_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    }
    'Initial clients';

    lives_ok {
        $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server';
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
    BOM::Config::Runtime->instance->app_config->system->suspend->expensive_api_calls(1);
    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('SuspendedDueToLoad', 'error when expensive calls are disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->expensive_api_calls(0);
    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('No error when unsuspended again');
};

subtest 'Return empty client portfolio' => sub {
    my $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    is_deeply($result->{contracts}, [], 'It should return empty array');
};

subtest 'Sell expired contracts' => sub {
    lives_ok {
        create_fmb(
            $client,
            buy_bet    => 1,
            is_expired => 1
        );
    }
    'Create expired contract for sell';

    my $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    is_deeply($result->{contracts}, [], 'It should return empty array');
};

subtest 'Return not expired client contracts' => sub {
    my $fmb;
    my $expected_contract_data;
    lives_ok {
        create_fmb($client, buy_bet => 1);

        my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});

        $fmb = $clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client->loginid, $client->currency, 'false'])->[0];

        $expected_contract_data = {
            contract_id    => $fmb->{id},
            transaction_id => $fmb->{buy_transaction_id},
            purchase_time  => Date::Utility->new($fmb->{purchase_time})->epoch,
            symbol         => $fmb->{underlying_symbol},
            payout         => $fmb->{payout_price},
            buy_price      => $fmb->{buy_price},
            date_start     => Date::Utility->new($fmb->{start_time})->epoch,
            expiry_time    => Date::Utility->new($fmb->{expiry_time})->epoch,
            contract_type  => $fmb->{bet_type},
            currency       => $client->currency,
            shortcode      => $fmb->{short_code},
            app_id         => undef
        };
    }
    'Create not expired contract and expected data';

    my $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    delete $result->{contracts}->[0]->{longcode};
    is_deeply($result->{contracts}, [$expected_contract_data], 'Should return contract data',);
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
