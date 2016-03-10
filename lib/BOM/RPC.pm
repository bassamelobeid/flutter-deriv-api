package BOM::RPC;

use Mojo::Base 'Mojolicious';
use Mojo::IOLoop;
use MojoX::JSON::RPC::Service;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Proc::CPUUsage;
use Time::HiRes;

use BOM::Platform::Context;
use BOM::Platform::Context::Request;
use BOM::Database::Rose::DB;
use BOM::RPC::v3::Utility;
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
use BOM::RPC::v3::App;

sub apply_usergroup {
    my ($cf, $log) = @_;

    if ($> == 0) {    # we are root
        my $group = $cf->{group};
        if ($group) {
            $group = (getgrnam $group)[2] unless $group =~ /^\d+$/;
            $(     = $group;                                          ## no critic
            $)     = "$group $group";                                 ## no critic
            $log->("Switched group: RGID=$( EGID=$)");
        }

        my $user = $cf->{user} // 'nobody';
        if ($user) {
            $user = (getpwnam $user)[2] unless $user =~ /^\d+$/;
            $<    = $user;                                            ## no critic
            $>    = $user;                                            ## no critic
            $log->("Switched user: RUID=$< EUID=$>");
        }
    }
    return;
}

sub register {
    my ($method, $code) = @_;
    return MojoX::JSON::RPC::Service->new->register(
        $method,
        sub {
            my ($params) = @_;

            my $args = {country_code => $params->{country}};
            my $loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
            if ($loginid and $loginid =~ /^(\D+)\d+$/) {
                $args->{broker_code} = $1;
            }
            $args->{language} = $params->{language} if ($params->{language});

            my $r = BOM::Platform::Context::Request->new($args);
            BOM::Platform::Context::request($r);

            goto &$code;
        });
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

    # hard-wire this here. A worker of this service is supposed to handle only
    # one request at a time. Hence, it must also C<accept> only one connection
    # at a time.
    $app->config->{hypnotoad}->{multi_accept} = 1;

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
                '/residence_list'            => register('residence_list',            \&BOM::RPC::v3::Static::residence_list),
                '/states_list'               => register('states_list',               \&BOM::RPC::v3::Static::states_list),
                '/ticks_history'             => register('ticks_history',             \&BOM::RPC::v3::TickStreamer::ticks_history),
                '/buy'                       => register('buy',                       \&BOM::RPC::v3::Transaction::buy),
                '/sell'                      => register('sell',                      \&BOM::RPC::v3::Transaction::sell),
                '/trading_times'             => register('trading_times',             \&BOM::RPC::v3::MarketDiscovery::trading_times),
                '/asset_index'               => register('asset_index',               \&BOM::RPC::v3::MarketDiscovery::asset_index),
                '/active_symbols'            => register('active_symbols',            \&BOM::RPC::v3::MarketDiscovery::active_symbols),
                '/contracts_for'             => register('contracts_for',             \&BOM::RPC::v3::Offerings::contracts_for),
                '/authorize'                 => register('authorize',                 \&BOM::RPC::v3::Authorize::authorize),
                '/logout'                    => register('logout',                    \&BOM::RPC::v3::Authorize::logout),
                '/get_limits'                => register('get_limits',                \&BOM::RPC::v3::Cashier::get_limits),
                '/tnc_approval'              => register('tnc_approval',              \&BOM::RPC::v3::Accounts::tnc_approval),
                '/paymentagent_list'         => register('paymentagent_list',         \&BOM::RPC::v3::Cashier::paymentagent_list),
                '/paymentagent_withdraw'     => register('paymentagent_withdraw',     \&BOM::RPC::v3::Cashier::paymentagent_withdraw),
                '/paymentagent_transfer'     => register('paymentagent_transfer',     \&BOM::RPC::v3::Cashier::paymentagent_transfer),
                '/transfer_between_accounts' => register('transfer_between_accounts', \&BOM::RPC::v3::Cashier::transfer_between_accounts),
                '/topup_virtual'             => register('topup_virtual',             \&BOM::RPC::v3::Cashier::topup_virtual),
                '/payout_currencies'         => register('payout_currencies',         \&BOM::RPC::v3::Accounts::payout_currencies),
                '/landing_company'           => register('landing_company',           \&BOM::RPC::v3::Accounts::landing_company),
                '/landing_company_details'   => register('landing_company_details',   \&BOM::RPC::v3::Accounts::landing_company_details),
                '/statement'                 => register('statement',                 \&BOM::RPC::v3::Accounts::statement),
                '/profit_table'              => register('profit_table',              \&BOM::RPC::v3::Accounts::profit_table),
                '/get_account_status'        => register('get_account_status',        \&BOM::RPC::v3::Accounts::get_account_status),
                '/change_password'           => register('change_password',           \&BOM::RPC::v3::Accounts::change_password),
                '/cashier_password'          => register('cashier_password',          \&BOM::RPC::v3::Accounts::cashier_password),
                '/get_settings'              => register('get_settings',              \&BOM::RPC::v3::Accounts::get_settings),
                '/set_settings'              => register('set_settings',              \&BOM::RPC::v3::Accounts::set_settings),
                '/get_self_exclusion'        => register('get_self_exclusion',        \&BOM::RPC::v3::Accounts::get_self_exclusion),
                '/set_self_exclusion'        => register('set_self_exclusion',        \&BOM::RPC::v3::Accounts::set_self_exclusion),
                '/balance'                   => register('balance',                   \&BOM::RPC::v3::Accounts::balance),
                '/api_token'                 => register('api_token',                 \&BOM::RPC::v3::Accounts::api_token),
                '/login_history'             => register('login_history',             \&BOM::RPC::v3::Accounts::login_history),
                '/set_account_currency'      => register('set_account_currency',      \&BOM::RPC::v3::Accounts::set_account_currency),
                '/set_financial_assessment'  => register('set_financial_assessment',  \&BOM::RPC::v3::Accounts::set_financial_assessment),
                '/get_financial_assessment'  => register('get_financial_assessment',  \&BOM::RPC::v3::Accounts::get_financial_assessment),
                '/verify_email'              => register('verify_email',              \&BOM::RPC::v3::NewAccount::verify_email),
                '/send_ask'                  => register('send_ask',                  \&BOM::RPC::v3::Contract::send_ask),
                '/get_bid'                   => register('get_bid',                   \&BOM::RPC::v3::Contract::get_bid),
                '/get_contract_details'      => register('get_contract_details',      \&BOM::RPC::v3::Contract::get_contract_details),
                '/new_account_real'          => register('new_account_real',          \&BOM::RPC::v3::NewAccount::new_account_real),
                '/new_account_maltainvest'   => register('new_account_maltainvest',   \&BOM::RPC::v3::NewAccount::new_account_maltainvest),
                '/new_account_japan'         => register('new_account_japan',         \&BOM::RPC::v3::NewAccount::new_account_japan),
                '/new_account_virtual'       => register('new_account_virtual',       \&BOM::RPC::v3::NewAccount::new_account_virtual),
                '/portfolio'                 => register('portfolio',                 \&BOM::RPC::v3::PortfolioManagement::portfolio),
                '/sell_expired'              => register('sell_expired',              \&BOM::RPC::v3::PortfolioManagement::sell_expired),
                '/proposal_open_contract'    => register('proposal_open_contract',    \&BOM::RPC::v3::PortfolioManagement::proposal_open_contract),

                '/app_register' => register('app_register', \&BOM::RPC::v3::App::register),
                '/app_list'     => register('app_list',     \&BOM::RPC::v3::App::list),
                '/app_get'      => register('app_get',      \&BOM::RPC::v3::App::get),
                '/app_delete'   => register('app_delete',   \&BOM::RPC::v3::App::delete),
            },
            exception_handler => sub {
                my ($dispatcher, $err, $m) = @_;
                my $path = $dispatcher->req->url->path;
                $path =~ s/\///;
                DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.call_failure.count', {tags => ["rpc:$path"]});
                $dispatcher->app->log->error(qq{Internal error: $err});
                $m->invalid_request('Invalid request');
                return;
            }
        });

    my $request_counter = 0;
    my $request_start;
    my @recent;
    my $call;
    my $cpu;

    $app->hook(
        before_dispatch => sub {
            my $c = shift;
            $cpu  = Proc::CPUUsage->new();
            $call = $c->req->url->path;
            $0    = "bom-rpc: " . $call;     ## no critic
            $call =~ s/\///;
            $request_start = [Time::HiRes::gettimeofday];
            DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.call.count', {tags => ["rpc:$call"]});
        });

    $app->hook(
        after_dispatch => sub {
            BOM::Database::Rose::DB->db_cache->finish_request_cycle;
            $request_counter++;
            my $request_end = [Time::HiRes::gettimeofday];
            my $end         = [gmtime $request_end->[0]];
            $end = sprintf(
                '%04d-%02d-%02d %02d:%02d:%06.3f',
                $end->[5] + 1900,
                $end->[4] + 1,
                @{$end}[3, 2, 1],
                $end->[0] + $request_end->[1] / 1_000_000
            );

            DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.call_success.count', {tags => ["rpc:$call"]});
            DataDog::DogStatsd::Helper::stats_timing(
                'bom_rpc.v_3.call.timing',
                (1000 * Time::HiRes::tv_interval($request_start)),
                {tags => ["rpc:$call"]});
            DataDog::DogStatsd::Helper::stats_timing('bom_rpc.v_3.cpuusage', $cpu->usage(), {tags => ["rpc:$call"]});

            push @recent, [$request_start, Time::HiRes::tv_interval($request_end, $request_start)];
            shift @recent if @recent > 50;

            my $usage = 0;
            $usage += $_->[1] for @recent;
            $usage = sprintf('%.2f', 100 * $usage / Time::HiRes::tv_interval($request_end, $recent[0]->[0]));

            $0 = "bom-rpc: (idle since $end #req=$request_counter us=$usage%)";    ## no critic
        });

    # set $0 after forking children
    Mojo::IOLoop->timer(0, sub { @recent = [[Time::HiRes::gettimeofday], 0]; $0 = "bom-rpc: (new)" });    ## no critic

    return;
}

1;
