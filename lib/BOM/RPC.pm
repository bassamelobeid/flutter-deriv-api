package BOM::RPC;

use Mojo::Base 'Mojolicious';
use Mojo::IOLoop;
use MojoX::JSON::RPC::Service;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Proc::CPUUsage;
use Time::HiRes;

use BOM::Platform::Context;
use BOM::Platform::Context::Request;
use BOM::Platform::Client;
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
use BOM::RPC::v3::Japan::NewAccount;
use BOM::RPC::v3::Mt5::Account;

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
    my ($method, $code, $require_auth) = @_;
    return MojoX::JSON::RPC::Service->new->register(
        $method,
        sub {
            my ($params) = @_;

            my $args = {};
            $args->{country_code} = $params->{country} if exists $params->{country};
            $params->{token} = $params->{args}->{authorize} if !$params->{token} && $params->{args}->{authorize};
            my $token_details = BOM::RPC::v3::Utility::get_token_details($params->{token});

            if ($token_details and exists $token_details->{loginid} and $token_details->{loginid} =~ /^(\D+)\d+$/) {
                $args->{broker_code} = $1;
            }
            $params->{token_details} = $token_details;
            $args->{language} = $params->{language} if ($params->{language});

            if (exists $params->{server_name}) {
                $params->{website_name} = BOM::RPC::v3::Utility::website_name(delete $params->{server_name});
            }

            my $r = BOM::Platform::Context::Request->new($args);
            BOM::Platform::Context::request($r);

            if ($require_auth) {
                return BOM::RPC::v3::Utility::invalid_token_error()
                    unless $token_details and exists $token_details->{loginid};

                my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});
                if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
                    return $auth_error;
                }
                $params->{client} = $client;
                $params->{app_id} = $token_details->{app_id};
            }

            my $verify_app_res;
            if ($params->{valid_source}) {
                $params->{source} = $params->{valid_source};
            } elsif ($params->{source}) {
                $verify_app_res = BOM::RPC::v3::App::verify_app({app_id => $params->{source}});
                return $verify_app_res if $verify_app_res->{error};
            }

            my $result = $code->(@_);

            if ($verify_app_res && ref $result eq 'HASH') {
                $result->{stash} = {%{$result->{stash} // {}}, %{$verify_app_res->{stash}}};
            }
            return $result;
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

    # A connection should accept only one requests, then it should terminate.
    $app->config->{hypnotoad}->{requests} = 1;

    my $log = $app->log;

    my $signature = "Binary.com RPC";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    apply_usergroup $app->config->{hypnotoad}, sub {
        $log->info(@_);
    };

    my @services = (
        ['residence_list', \&BOM::RPC::v3::Static::residence_list],
        ['states_list',    \&BOM::RPC::v3::Static::states_list],
        ['website_status', \&BOM::RPC::v3::Static::website_status],

        ['ticks_history', \&BOM::RPC::v3::TickStreamer::ticks_history],
        ['ticks',         \&BOM::RPC::v3::TickStreamer::ticks],

        ['buy', \&BOM::RPC::v3::Transaction::buy],
        ['sell', \&BOM::RPC::v3::Transaction::sell, 1],

        ['trading_times',         \&BOM::RPC::v3::MarketDiscovery::trading_times],
        ['asset_index',           \&BOM::RPC::v3::MarketDiscovery::asset_index],
        ['active_symbols',        \&BOM::RPC::v3::MarketDiscovery::active_symbols],
        ['get_corporate_actions', \&BOM::RPC::v3::MarketDiscovery::get_corporate_actions],

        ['contracts_for', \&BOM::RPC::v3::Offerings::contracts_for],

        ['authorize', \&BOM::RPC::v3::Authorize::authorize],
        ['logout',    \&BOM::RPC::v3::Authorize::logout],

        ['get_limits',                \&BOM::RPC::v3::Cashier::get_limits,                1],
        ['paymentagent_list',         \&BOM::RPC::v3::Cashier::paymentagent_list],
        ['paymentagent_withdraw',     \&BOM::RPC::v3::Cashier::paymentagent_withdraw,     1],
        ['paymentagent_transfer',     \&BOM::RPC::v3::Cashier::paymentagent_transfer,     1],
        ['transfer_between_accounts', \&BOM::RPC::v3::Cashier::transfer_between_accounts, 1],
        ['cashier',                   \&BOM::RPC::v3::Cashier::cashier,                   1],
        ['topup_virtual',             \&BOM::RPC::v3::Cashier::topup_virtual,             1],

        ['payout_currencies',       \&BOM::RPC::v3::Accounts::payout_currencies],
        ['landing_company',         \&BOM::RPC::v3::Accounts::landing_company],
        ['landing_company_details', \&BOM::RPC::v3::Accounts::landing_company_details],

        ['statement',                \&BOM::RPC::v3::Accounts::statement,                1],
        ['profit_table',             \&BOM::RPC::v3::Accounts::profit_table,             1],
        ['get_account_status',       \&BOM::RPC::v3::Accounts::get_account_status,       1],
        ['change_password',          \&BOM::RPC::v3::Accounts::change_password,          1],
        ['cashier_password',         \&BOM::RPC::v3::Accounts::cashier_password,         1],
        ['reset_password',           \&BOM::RPC::v3::Accounts::reset_password],
        ['get_settings',             \&BOM::RPC::v3::Accounts::get_settings,             1],
        ['set_settings',             \&BOM::RPC::v3::Accounts::set_settings,             1],
        ['get_self_exclusion',       \&BOM::RPC::v3::Accounts::get_self_exclusion,       1],
        ['set_self_exclusion',       \&BOM::RPC::v3::Accounts::set_self_exclusion,       1],
        ['balance',                  \&BOM::RPC::v3::Accounts::balance,                  1],
        ['api_token',                \&BOM::RPC::v3::Accounts::api_token,                1],
        ['login_history',            \&BOM::RPC::v3::Accounts::login_history,            1],
        ['set_account_currency',     \&BOM::RPC::v3::Accounts::set_account_currency,     1],
        ['tnc_approval',             \&BOM::RPC::v3::Accounts::tnc_approval,             1],
        ['set_financial_assessment', \&BOM::RPC::v3::Accounts::set_financial_assessment, 1],
        ['get_financial_assessment', \&BOM::RPC::v3::Accounts::get_financial_assessment, 1],
        ['reality_check',            \&BOM::RPC::v3::Accounts::reality_check,            1],

        ['verify_email', \&BOM::RPC::v3::NewAccount::verify_email],

        ['send_ask', \&BOM::RPC::v3::Contract::send_ask],
        ['get_bid',  \&BOM::RPC::v3::Contract::get_bid],
        ['get_contract_details', \&BOM::RPC::v3::Contract::get_contract_details, 1],

        ['new_account_real',        \&BOM::RPC::v3::NewAccount::new_account_real,         1],
        ['new_account_maltainvest', \&BOM::RPC::v3::NewAccount::new_account_maltainvest,  1],
        ['new_account_japan',       \&BOM::RPC::v3::NewAccount::new_account_japan,        1],
        ['new_account_virtual',     \&BOM::RPC::v3::NewAccount::new_account_virtual],
        ['jp_knowledge_test',       \&BOM::RPC::v3::Japan::NewAccount::jp_knowledge_test, 1],

        ['portfolio',              \&BOM::RPC::v3::PortfolioManagement::portfolio,              1],
        ['sell_expired',           \&BOM::RPC::v3::PortfolioManagement::sell_expired,           1],
        ['proposal_open_contract', \&BOM::RPC::v3::PortfolioManagement::proposal_open_contract, 1],

        ['app_register', \&BOM::RPC::v3::App::register,   1],
        ['app_list',     \&BOM::RPC::v3::App::list,       1],
        ['app_get',      \&BOM::RPC::v3::App::get,        1],
        ['app_update',   \&BOM::RPC::v3::App::update,     1],
        ['app_delete',   \&BOM::RPC::v3::App::delete,     1],
        ['oauth_apps',   \&BOM::RPC::v3::App::oauth_apps, 1],

        ['mt5_new_account',     \&BOM::RPC::v3::Mt5::Account::mt5_new_account,     1],
        ['mt5_get_settings',    \&BOM::RPC::v3::Mt5::Account::mt5_get_settings,    1],
        ['mt5_set_settings',    \&BOM::RPC::v3::Mt5::Account::mt5_set_settings,    1],
        ['mt5_password_check',  \&BOM::RPC::v3::Mt5::Account::mt5_password_check,  1],
        ['mt5_password_change', \&BOM::RPC::v3::Mt5::Account::mt5_password_change, 1],
        ['mt5_deposit',         \&BOM::RPC::v3::Mt5::Account::mt5_deposit,         1],
        ['mt5_withdrawal',      \&BOM::RPC::v3::Mt5::Account::mt5_withdrawal,      1],
    );
    my $services = {};
    foreach my $srv (@services) {
        $services->{'/' . $srv->[0]} = register(@$srv);
    }

    $app->plugin(
        'json_rpc_dispatcher' => {
            services          => $services,
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
