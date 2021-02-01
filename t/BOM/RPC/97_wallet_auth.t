use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Platform::Token::API;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::RPC;
use BOM::RPC::Registry;
use Struct::Dumb;

struct
    def               => [qw(name code auth is_async caller)],
    named_constructor => 1;
my %params = (
    name     => 'dummy',
    code     => sub { 'success' },
    auth     => undef,
    is_async => 0,
    caller   => 'dummy',
);
my $def = def(%params);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my $token  = BOM::Platform::Token::API->new->create_token($client->loginid, 'test');

subtest 'client and runtime checks' => sub {

    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

    is BOM::RPC::wrap_rpc_sub($def)->(), 'success', 'sub with no auth';

    $params{auth} = ['wallet'];
    $def = def(%params);

    cmp_deeply(
        BOM::RPC::wrap_rpc_sub($def)->(),
        {
            error => {
                code              => 'InvalidToken',
                message_to_client => 'The token is invalid.'
            }
        },
        'sub with wallet auth, no token'
    );

    is BOM::RPC::wrap_rpc_sub($def)->({token => $token}), 'success', 'wallets disabled, trading token can call wallet only sub';

    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(0);

    cmp_deeply(
        BOM::RPC::wrap_rpc_sub($def)->({token => $token}),
        {
            error => {
                code              => 'PermissionDenied',
                message_to_client => 'This resource cannot be accessed by this account type.'
            }
        },
        'trading token cannot access wallet sub when wallets enabled'
    );

    $params{auth} = ['wallet', 'trading'];
    $def = def(%params);

    is BOM::RPC::wrap_rpc_sub($def)->({token => $token}), 'success', 'both types ok for trading token';

    my $mock_lc_wallet = Test::MockModule->new('LandingCompany::Wallet');
    $mock_lc_wallet->mock(get_wallet_for_broker => sub { 1 });

    is BOM::RPC::wrap_rpc_sub($def)->({token => $token}), 'success', 'both types ok for wallet token';

    $params{auth} = ['wallet'];
    $def = def(%params);

    is BOM::RPC::wrap_rpc_sub($def)->({token => $token}), 'success', 'wallet token is ok for wallet only sub';

    $params{auth} = ['trading'];
    $def = def(%params);

    cmp_deeply(
        BOM::RPC::wrap_rpc_sub($def)->({token => $token}),
        {
            error => {
                code              => 'PermissionDenied',
                message_to_client => 'This resource cannot be accessed by this account type.'
            }
        },
        'wallet token cannot access trading sub'
    );

    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

    is BOM::RPC::wrap_rpc_sub($def)->({token => $token}), 'success', 'no error for wallet token if wallets are suspended';

    $mock_lc_wallet->unmock_all;

    is BOM::RPC::wrap_rpc_sub($def)->({token => $token}), 'success', 'no error for trading token if wallets are suspended';
};

subtest 'auth attribute of all rpc definitions' => sub {
    my @defs = BOM::RPC::Registry::get_service_defs;

    for my $d (@defs) {
        ok((!defined($d->auth) or ref $d->auth eq 'ARRAY'), 'auth of ' . $d->name . ' is undef or array');
    }
};

done_testing;
