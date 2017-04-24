use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::Warn;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use DateTime;

use BOM::Test::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Database::Model::AccessToken;
use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Database::Model::OAuth;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use utf8;

my ($client, $client_token, $oauth_token);
my ($t, $rpc_ct);
my $method = 'proposal_open_contract';

my @params = (
    $method,
    {
        language => 'EN',
        country  => 'ru',
        args     => {},
    });

$t = Test::Mojo->new('BOM::RPC');
$rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);

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

        my $m = BOM::Database::Model::AccessToken->new;

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
        my $module = Test::MockModule->new('Client::Account');
        $module->mock('new', sub { });

        $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'It should check auth');
    }

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('It should be success using token');

    $params[1]->{token} = $oauth_token;

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('It should be success using oauth token');
};

done_testing();

sub _create_contract {
    my %args = @_;

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD);

    my $client = $args{client};
    #postpone 10 minutes to avoid conflicts
    my $now = Date::Utility->new('2005-09-21 06:46:00');
    $now = $now->plus_time_interval('10m');

    my $old_tick1 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 99,
        underlying => 'R_50',
    });

    my $old_tick2 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 52,
        underlying => 'R_50',
    });

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });
    my $underlying    = create_underlying('R_50');
    my $contract_data = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        stake        => 100,
        date_start   => $now->epoch - 100,
        date_expiry  => $now->epoch - 50,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        barrier      => 'S0P',
    };

    my $contract = produce_contract($contract_data);
    my $txn      = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => 100,
        payout        => $contract->payout,
        amount_type   => 'stake',
        purchase_date => $now->epoch - 101,
    });

    my $error = $txn->buy(skip_validation => 1);
    die $error if $error;

    return ($txn->contract_id, $contract);
}
