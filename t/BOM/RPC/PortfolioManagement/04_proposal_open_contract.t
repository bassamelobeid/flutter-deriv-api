use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use DateTime;

use Test::BOM::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Market::Data::DatabaseAPI;
use BOM::Database::Model::AccessToken;
use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw( produce_contract );

use utf8;

my ($client, $client_token, $session);
my ($t, $rpc_ct);
my $method = 'proposal_open_contract';

my @params = (
    $method,
    {
        language => 'RU',
        source   => 1,
        country  => 'ru',
        args     => {},
    });

$t = Test::Mojo->new('BOM::RPC');
$rpc_ct = Test::BOM::RPC::Client->new(ua => $t->app->ua);
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

        $session = BOM::Platform::SessionCookie->new(
            loginid => $client->loginid,
            email   => $client->email,
        )->token;
    }
    'Initial clients';
};

subtest 'Auth client' => sub {
    $rpc_ct->call_ok(@params)->has_no_system_error->result_is_deeply({
            error => {
                message_to_client => 'Токен недействителен.',
                code              => 'InvalidToken',
            }
        },
        'It should return error: InvalidToken'
    );

    $params[1]->{token} = 'wrong token';
    $rpc_ct->call_ok(@params)->has_no_system_error->result_is_deeply({
            error => {
                message_to_client => 'Токен недействителен.',
                code              => 'InvalidToken',
            }
        },
        'It should return error: InvalidToken'
    );

    delete $params[1]->{token};
    $rpc_ct->call_ok(@params)->has_no_system_error->result_is_deeply({
            error => {
                message_to_client => 'Токен недействителен.',
                code              => 'InvalidToken',
            }
        },
        'It should return error: InvalidToken'
    );

    $params[1]->{token} = $client_token;

    {
        my $module = Test::MockModule->new('BOM::Platform::Client');
        $module->mock('new', sub { });

        $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'It should check auth');
    }

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('It should be success using token');

    $params[1]->{token} = $session;

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('It should be success using session');
};

subtest $method => sub {
    my ($contract_id, $contract);
    my @expected_contract_fields;

    lives_ok {
        ($contract_id, $contract) = create_contract(client => $client);
    }
    'Initial contract';

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error;
    lives_ok {
        my $bid = BOM::RPC::v3::Contract::get_bid({
            short_code  => $contract->shortcode,
            contract_id => $contract_id,
            currency    => $client->currency,
            is_sold     => $contract->is_sold,
        });

        @expected_contract_fields = qw/ buy_price purchase_time account_id is_sold /;
        push @expected_contract_fields, keys %$bid;
    }
    'Get extected data';
    is_deeply([sort keys %{$rpc_ct->result->{$contract_id}}], [sort @expected_contract_fields], 'Should return contract and bid data');

    $params[1]->{contract_id} = $contract_id;
    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error;
    lives_ok {
        my $bid = BOM::RPC::v3::Contract::get_bid({
            short_code  => $contract->shortcode,
            contract_id => $contract_id,
            currency    => $client->currency,
            is_sold     => $contract->is_sold,
        });

        @expected_contract_fields = qw/ buy_price purchase_time account_id is_sold /;
        push @expected_contract_fields, keys %$bid;
    }
    'Get extected data';
    is_deeply([sort keys %{$rpc_ct->result->{$contract_id}}], [sort @expected_contract_fields], 'Should return contract and bid data by contract_id');

    my $contract_factory = Test::MockModule->new('BOM::RPC::v3::Contract');
    $contract_factory->mock('produce_contract', sub { die });

    $rpc_ct->call_ok(@params)->has_no_system_error->result_is_deeply({
            $contract_id => {
                error => {
                    message_to_client => 'Извините, при обработке Вашего запроса произошла ошибка.',
                    code              => 'GetProposalFailure',
                },
            },
        },
        'Should return error instead contract data',
    );
};

done_testing();

sub create_contract {
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
    my $underlying    = BOM::Market::Underlying->new('R_50');
    my $contract_data = {
        underlying   => $underlying,
        bet_type     => 'FLASHU',
        currency     => 'USD',
        stake        => 100,
        date_start   => $now->epoch - 100,
        date_expiry  => $now->epoch - 50,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        barrier      => 'S0P',
    };

    if ($args{spread}) {
        delete $contract_data->{date_expiry};
        delete $contract_data->{barrier};
        $contract_data->{bet_type}         = 'SPREADU';
        $contract_data->{amount_per_point} = 1;
        $contract_data->{stop_type}        = 'point';
        $contract_data->{stop_profit}      = 10;
        $contract_data->{stop_loss}        = 10;
    }
    my $contract = produce_contract($contract_data);

    my $txn = BOM::Product::Transaction->new({
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
