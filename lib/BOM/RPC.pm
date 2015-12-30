package BOM::RPC;

use Mojo::Base 'Mojolicious';
use MojoX::JSON::RPC::Service;

use BOM::Database::Rose::DB;
use BOM::Platform::Runtime;
use BOM::Platform::Context ();
use BOM::Platform::Context::Request;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Static;
use BOM::RPC::v3::TickStreamer;
use BOM::RPC::v3::Transaction;
use BOM::RPC::v3::MarketDiscovery;
use BOM::RPC::v3::Offerings;
use BOM::RPC::v3::Authorize;
use BOM::RPC::v3::Cashier;

sub startup {
    my $app = shift;

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $app->log->error("EventLoop error: $err");
        });

    $app->moniker('rpc');
    $app->plugin('Config' => {file => $ENV{RPC_CONFIG} || '/etc/rmg/rpc.conf'});

    my $log = $app->log;

    my $signature = "Binary.com RPC";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    $app->plugin(
        'json_rpc_dispatcher' => {
            services => {
                '/landing_company' => MojoX::JSON::RPC::Service->new->register('landing_company', \&BOM::RPC::v3::Accounts::landing_company),
                '/residence_list'  => MojoX::JSON::RPC::Service->new->register('residence_list',  \&BOM::RPC::v3::Static::residence_list),
                '/states_list'     => MojoX::JSON::RPC::Service->new->register('states_list',     \&BOM::RPC::v3::Static::states_list),
                '/ticks_history'   => MojoX::JSON::RPC::Service->new->register('ticks_history',   \&BOM::RPC::v3::TickStreamer::ticks_history),
                '/buy'             => MojoX::JSON::RPC::Service->new->register('buy',             \&BOM::RPC::v3::Transaction::buy),
                '/sell'            => MojoX::JSON::RPC::Service->new->register('sell',            \&BOM::RPC::v3::Transaction::sell),
                '/trading_times'   => MojoX::JSON::RPC::Service->new->register('trading_times',   \&BOM::RPC::v3::MarketDiscovery::trading_times),
                '/asset_index'     => MojoX::JSON::RPC::Service->new->register('asset_index',     \&BOM::RPC::v3::MarketDiscovery::asset_index),
                '/active_symbols'  => MojoX::JSON::RPC::Service->new->register('active_symbols',  \&BOM::RPC::v3::MarketDiscovery::active_symbols),
                '/contracts_for'   => MojoX::JSON::RPC::Service->new->register('contracts_for',   \&BOM::RPC::v3::Offerings::contracts_for),
                '/authorize'       => MojoX::JSON::RPC::Service->new->register('authorize',       \&BOM::RPC::v3::Authorize::authorize),
                '/logout'          => MojoX::JSON::RPC::Service->new->register('logout',          \&BOM::RPC::v3::Authorize::logout),
                '/get_limits'      => MojoX::JSON::RPC::Service->new->register('get_limits',      \&BOM::RPC::v3::Cashier::get_limits),
                '/paymentagent_list' => MojoX::JSON::RPC::Service->new->register('paymentagent_list', \&BOM::RPC::v3::Cashier::paymentagent_list),
                '/paymentagent_withdraw' =>
                    MojoX::JSON::RPC::Service->new->register('paymentagent_withdraw', \&BOM::RPC::v3::Cashier::paymentagent_withdraw),
                '/paymentagent_transfer' =>
                    MojoX::JSON::RPC::Service->new->register('paymentagent_transfer', \&BOM::RPC::v3::Cashier::paymentagent_transfer),
                '/transfer_between_accounts' =>
                    MojoX::JSON::RPC::Service->new->register('transfer_between_accounts', \&BOM::RPC::v3::Cashier::transfer_between_accounts),
                '/topup_virtual' => MojoX::JSON::RPC::Service->new->register('topup_virtual', \&BOM::RPC::v3::Cashier::topup_virtual),
            },
            exception_handler => sub {
                my ($dispatcher, $err, $m) = @_;
                $dispatcher->app->log->error(qq{Internal error: $err});
                $m->invalid_request('Invalid request');
                return;
            }
        });

    $app->hook(
        after_dispatch => sub {
            BOM::Database::Rose::DB->db_cache->finish_request_cycle;
        });

    return;
}

1;
