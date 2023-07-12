use strict;
use warnings;
use utf8;

no indirect;
use feature qw(state);

use Test::More;
use Test::Mojo;
use Test::Deep qw(cmp_deeply);
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use Test::Fatal     qw(lives_ok);

use MojoX::JSON::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token;
use BOM::User::Client;
use BOM::User::Wallet;
use BOM::Database::Model::OAuth;
use BOM::Platform::Token::API;
use BOM::Test::Helper::Client;

my $rpc_ct;
subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

subtest 'It should be able to create trading account ' => sub {
    my $params = +{};

    my ($user, $wallet_generator) = BOM::Test::Helper::Client::create_wallet_factory('za', 'Gauteng');

    (undef, $params->{token}) = $wallet_generator->(qw(CRW doughflow USD));

    my $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to DF wallet";

    my $acc = BOM::User::Client->new({loginid => $result->{client_id}})->default_account;
    is(($acc ? $acc->currency_code : ''), 'USD', "It should have the same currency as wallet account");

    (undef, $params->{token}) = $wallet_generator->(qw(CRW p2p USD));
    $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    $acc    = BOM::User::Client->new({loginid => $result->{client_id}})->default_account;
    is(($acc ? $acc->currency_code : ''), 'USD', "It should have the same currency as wallet account");

    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to P2P wallet";

    $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_error->error_code_is("InvalidAccount", "It should fail duplicate check");
};

subtest 'It should not allow to create duplicated trading account for the same wallet' => sub {
    my ($user, $wallet_generator) = BOM::Test::Helper::Client::create_wallet_factory('za', 'Gauteng');

    my $params = +{};
    (undef, $params->{token}) = $wallet_generator->(qw(CRW doughflow USD));

    my $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to DF wallet";

    $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_error->error_code_is("InvalidAccount", "It should fail duplicate check");
};

subtest 'It should allow to create 2 trading accounts of the same type connected to different  wallet' => sub {
    my ($user, $wallet_generator) = BOM::Test::Helper::Client::create_wallet_factory('za', 'Gauteng');

    my $params = +{};
    (undef, $params->{token}) = $wallet_generator->(qw(CRW doughflow USD));

    my $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to DF wallet";

    (undef, $params->{token}) = $wallet_generator->(qw(CRW p2p USD));
    $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to DF wallet";
};

subtest 'It should not allow to create 2 trading accounts for unsupported wallet types' => sub {
    my ($user, $wallet_generator) = BOM::Test::Helper::Client::create_wallet_factory('za', 'Gauteng');

    my $params = +{};
    (undef, $params->{token}) = $wallet_generator->(qw(CRW paymentagent USD));
    $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_error->error_code_is("InvalidAccount", "It should fail duplicate check");
};

subtest 'It should not allow to create 2 trading accounts for unsupported wallet types' => sub {
    my ($user, $wallet_generator) = BOM::Test::Helper::Client::create_wallet_factory('za', 'Gauteng');

    my $params = +{};
    (undef, $params->{token}) = $wallet_generator->(qw(CRW paymentagent USD));
    $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_error->error_code_is("InvalidAccount", "It should fail duplicate check");
};

subtest 'It should be able to create trading account for maltainvest' => sub {
    my $params = +{};
    my ($user, $wallet_generator) = BOM::Test::Helper::Client::create_wallet_factory('za', 'Gauteng');

    (undef, $params->{token}) = $wallet_generator->(qw(MFW doughflow USD));

    my $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^MF\d+}, "It should create trading account attached to DF wallet";
};

done_testing;
