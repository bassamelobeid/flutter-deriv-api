use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use BOM::Test::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::Database::Model::OAuth;
use BOM::Database::ClientDB;
use Email::Stuffer::TestLinks;

my $expected_result = {
    error => {
        message_to_client => 'The token is invalid.',
        code              => 'InvalidToken',
    },
    stash => {
        app_markup_percentage      => 0,
        valid_source               => 1,
        source_bypass_verification => 0
    },
};

use utf8;

my ($vclient, $vclient_token, $client, $client_token, $oauth_token);
my ($t, $rpc_ct);
my $method = 'sell_expired';

my @params = (
    $method,
    {
        language => 'EN',
        country  => 'ru',
        args     => {sell_expired => 1},
    });

subtest 'Initialization' => sub {
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $vclient = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });

        $client->payment_free_gift(
            currency => 'USD',
            amount   => 500,
            remark   => 'free gift',
        );

        my $m = BOM::Database::Model::AccessToken->new;

        $client_token  = $m->create_token($client->loginid,  'test token');
        $vclient_token = $m->create_token($vclient->loginid, 'test token');

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
};

subtest 'Sell expired contract' => sub {
    create_fmb(
        $client,
        is_expired => 1,
        buy_bet    => 1
    );

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result_is_deeply({
            count => 1,
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0
            }
        },
        'It should return counts of sold contracts'
    );

    lives_ok {
        create_fmb($client);
    }
    'Create expired contract for sell';

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result_is_deeply({
            count => 0,
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0
            }
        },
        'It should return 0 if there are not expired contracts'
    );
};

subtest 'Emergency error while sell contract' => sub {
    my $module = Test::MockModule->new('BOM::Transaction');
    $module->mock('sell_expired_contracts', sub { die });

    $rpc_ct->call_ok(@params)->has_error->error_code_is('SellExpiredError');
};

done_testing();

sub create_fmb {
    my ($client, %params) = @_;

    my $account = $client->set_default_account('USD');
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb_with_ticks({
        %params,
        type               => 'fmb_higher_lower_call_buy',
        short_code_prefix  => 'CALL_R_100_26.49',
        short_code_postfix => 'S0P_0',
        account_id         => $account->id,
        buy_bet            => $params{buy_bet} || 0,
    });
}
