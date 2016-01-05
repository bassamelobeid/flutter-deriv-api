package BOM::RPC;

use 5.010;    # `state`

use Mojo::Base 'Mojolicious';
use Mojo::IOLoop;
use MojoX::JSON::RPC::Service;

use BOM::Database::Rose::DB;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Static;
use BOM::RPC::v3::TickStreamer;
use BOM::RPC::v3::Transaction;
use BOM::RPC::v3::MarketDiscovery;
use BOM::RPC::v3::Offerings;
use BOM::RPC::v3::Authorize;
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::NewAccount;
use BOM::RPC::v3::Contract;
use BOM::RPC::v3::PortfolioManagement;

sub apply_usergroup {
    my ($cf, $log) = @_;

    if ($> == 0) {    # we are root
        my $group = $cf->{group};
        if ($group) {
            $group = (getgrnam $group)[2] unless $group =~ /^\d+$/;
            $(     = $group;                                          # rgid
            $)     = "$group $group";                                 # egid -- reset all group memberships
            $log->("Switched group: RGID=$( EGID=$)");
        }

        my $user = $cf->{user} // 'nobody';
        if ($user) {
            $user = (getpwnam $user)[2] unless $user =~ /^\d+$/;
            $<    = $user;                                            # ruid
            $>    = $user;                                            # euid
            $log->("Switched user: RUID=$< EUID=$>");
        }
    }
    return;
}

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

    apply_usergroup $app->config->{hypnotoad}, sub {
        $log->info(@_);
    };

    $app->plugin(
        'json_rpc_dispatcher' => {
            services => {
                '/residence_list' => MojoX::JSON::RPC::Service->new->register('residence_list', \&BOM::RPC::v3::Static::residence_list),
                '/states_list'    => MojoX::JSON::RPC::Service->new->register('states_list',    \&BOM::RPC::v3::Static::states_list),
                '/ticks_history'  => MojoX::JSON::RPC::Service->new->register('ticks_history',  \&BOM::RPC::v3::TickStreamer::ticks_history),
                '/buy'            => MojoX::JSON::RPC::Service->new->register('buy',            \&BOM::RPC::v3::Transaction::buy),
                '/sell'           => MojoX::JSON::RPC::Service->new->register('sell',           \&BOM::RPC::v3::Transaction::sell),
                '/trading_times'  => MojoX::JSON::RPC::Service->new->register('trading_times',  \&BOM::RPC::v3::MarketDiscovery::trading_times),
                '/asset_index'    => MojoX::JSON::RPC::Service->new->register('asset_index',    \&BOM::RPC::v3::MarketDiscovery::asset_index),
                '/active_symbols' => MojoX::JSON::RPC::Service->new->register('active_symbols', \&BOM::RPC::v3::MarketDiscovery::active_symbols),
                '/contracts_for'  => MojoX::JSON::RPC::Service->new->register('contracts_for',  \&BOM::RPC::v3::Offerings::contracts_for),
                '/authorize'      => MojoX::JSON::RPC::Service->new->register('authorize',      \&BOM::RPC::v3::Authorize::authorize),
                '/logout'         => MojoX::JSON::RPC::Service->new->register('logout',         \&BOM::RPC::v3::Authorize::logout),
                '/get_limits'     => MojoX::JSON::RPC::Service->new->register('get_limits',     \&BOM::RPC::v3::Cashier::get_limits),
                '/paymentagent_list' => MojoX::JSON::RPC::Service->new->register('paymentagent_list', \&BOM::RPC::v3::Cashier::paymentagent_list),
                '/paymentagent_withdraw' =>
                    MojoX::JSON::RPC::Service->new->register('paymentagent_withdraw', \&BOM::RPC::v3::Cashier::paymentagent_withdraw),
                '/paymentagent_transfer' =>
                    MojoX::JSON::RPC::Service->new->register('paymentagent_transfer', \&BOM::RPC::v3::Cashier::paymentagent_transfer),
                '/transfer_between_accounts' =>
                    MojoX::JSON::RPC::Service->new->register('transfer_between_accounts', \&BOM::RPC::v3::Cashier::transfer_between_accounts),
                '/topup_virtual'     => MojoX::JSON::RPC::Service->new->register('topup_virtual',     \&BOM::RPC::v3::Cashier::topup_virtual),
                '/payout_currencies' => MojoX::JSON::RPC::Service->new->register('payout_currencies', \&BOM::RPC::v3::Accounts::payout_currencies),
                '/landing_company'   => MojoX::JSON::RPC::Service->new->register('landing_company',   \&BOM::RPC::v3::Accounts::landing_company),
                '/landing_company_details' =>
                    MojoX::JSON::RPC::Service->new->register('landing_company_details', \&BOM::RPC::v3::Accounts::landing_company_details),
                '/statement'          => MojoX::JSON::RPC::Service->new->register('statement',          \&BOM::RPC::v3::Accounts::statement),
                '/profit_table'       => MojoX::JSON::RPC::Service->new->register('profit_table',       \&BOM::RPC::v3::Accounts::profit_table),
                '/get_account_status' => MojoX::JSON::RPC::Service->new->register('get_account_status', \&BOM::RPC::v3::Accounts::get_account_status),
                '/change_password'    => MojoX::JSON::RPC::Service->new->register('change_password',    \&BOM::RPC::v3::Accounts::change_password),
                '/cashier_password'   => MojoX::JSON::RPC::Service->new->register('cashier_password',   \&BOM::RPC::v3::Accounts::cashier_password),
                '/get_settings'       => MojoX::JSON::RPC::Service->new->register('get_settings',       \&BOM::RPC::v3::Accounts::get_settings),
                '/set_settings'       => MojoX::JSON::RPC::Service->new->register('set_settings',       \&BOM::RPC::v3::Accounts::set_settings),
                '/get_self_exclusion' => MojoX::JSON::RPC::Service->new->register('get_self_exclusion', \&BOM::RPC::v3::Accounts::get_self_exclusion),
                '/set_self_exclusion' => MojoX::JSON::RPC::Service->new->register('set_self_exclusion', \&BOM::RPC::v3::Accounts::set_self_exclusion),
                '/balance'            => MojoX::JSON::RPC::Service->new->register('balance',            \&BOM::RPC::v3::Accounts::balance),
                '/api_token'          => MojoX::JSON::RPC::Service->new->register('api_token',          \&BOM::RPC::v3::Accounts::api_token),
                '/verify_email'       => MojoX::JSON::RPC::Service->new->register('verify_email',       \&BOM::RPC::v3::NewAccount::verify_email),
                '/send_ask'           => MojoX::JSON::RPC::Service->new->register('send_ask',           \&BOM::RPC::v3::Contract::send_ask),
                '/get_bid'            => MojoX::JSON::RPC::Service->new->register('get_bid',            \&BOM::RPC::v3::Contract::get_bid),
                '/new_account_real'   => MojoX::JSON::RPC::Service->new->register('new_account_real',   \&BOM::RPC::v3::NewAccount::new_account_real),
                '/new_account_maltainvest' =>
                    MojoX::JSON::RPC::Service->new->register('new_account_maltainvest', \&BOM::RPC::v3::NewAccount::new_account_maltainvest),
                '/new_account_virtual' =>
                    MojoX::JSON::RPC::Service->new->register('new_account_virtual', \&BOM::RPC::v3::NewAccount::new_account_virtual),
                '/portfolio' => MojoX::JSON::RPC::Service->new->register('portfolio', \&BOM::RPC::v3::PortfolioManagement::portfolio),
            },
            exception_handler => sub {
                my ($dispatcher, $err, $m) = @_;
                $dispatcher->app->log->error(qq{Internal error: $err});
                $m->invalid_request('Invalid request');
                return;
            }
        });

    $app->hook(
        before_dispatch => sub {
            my $c = shift;
            $0 = "bom-rpc: " . $c->req->url->path;    ## no critic
        });

    $app->hook(
        after_dispatch => sub {
            BOM::Database::Rose::DB->db_cache->finish_request_cycle;
            state $request_counter = 1;
            $0 = "bom-rpc: (idle $request_counter)";    ## no critic
            $request_counter++;
        });

    # set $0 after forking children
    Mojo::IOLoop->timer(0, sub { $0 = "bom-rpc: (new)" });    ## no critic

    return;
}

1;
