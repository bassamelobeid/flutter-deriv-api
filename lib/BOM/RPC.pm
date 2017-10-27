package BOM::RPC;

use strict;
use warnings;
no indirect;

use Mojo::Base 'Mojolicious';
use Mojo::IOLoop;
use MojoX::JSON::RPC::Service;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Proc::CPUUsage;
use Time::HiRes;
use Try::Tiny;
use Path::Tiny;
use JSON::MaybeXS;
use Scalar::Util q(blessed);

use BOM::Platform::Context qw(localize);
use BOM::Platform::Context::Request;
use Client::Account;
use BOM::Database::Rose::DB;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Static;
use BOM::RPC::v3::TickStreamer;
use BOM::RPC::v3::Transaction;
use BOM::RPC::v3::MarketDiscovery;
use BOM::RPC::v3::Authorize;
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::NewAccount;
use BOM::RPC::v3::Contract;
use BOM::RPC::v3::PortfolioManagement;
use BOM::RPC::v3::App;
use BOM::RPC::v3::Japan::NewAccount;
use BOM::RPC::v3::MT5::Account;
use BOM::RPC::v3::CopyTrading::Statistics;
use BOM::RPC::v3::CopyTrading;
use BOM::Transaction::Validation;
use BOM::RPC::v3::DocumentUpload;

my $json = JSON::MaybeXS->new;

sub apply_usergroup {
    my ($cf, $log) = @_;

    if ($> == 0) {    # we are root
        my $group = $cf->{group};
        if ($group) {
            $group = (getgrnam $group)[2] unless $group =~ /^\d+$/;
            $(     = $group;                                          ## no critic (RequireLocalizedPunctuationVars)
            $)     = "$group $group";                                 ## no critic (RequireLocalizedPunctuationVars)
            $log->("Switched group: RGID=$( EGID=$)");
        }

        my $user = $cf->{user} // 'nobody';
        if ($user) {
            $user = (getpwnam $user)[2] unless $user =~ /^\d+$/;
            $<    = $user;                                            ## no critic (RequireLocalizedPunctuationVars)
            $>    = $user;                                            ## no critic (RequireLocalizedPunctuationVars)
            $log->("Switched user: RUID=$< EUID=$>");
        }
    }
    return;
}

sub _auth {
    my $params = shift;

    my $token_details = $params->{token_details};
    return BOM::RPC::v3::Utility::invalid_token_error()
        unless $token_details and exists $token_details->{loginid};

    my $client = Client::Account->new({loginid => $token_details->{loginid}});

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }
    $params->{client} = $client;
    $params->{app_id} = $token_details->{app_id};
    return;
}

sub register {
    my ($method, $code, $before_actions) = @_;

    return MojoX::JSON::RPC::Service->new->register(
        $method,
        sub {
            # let's have an copy, which will be dumped to log if something goes wrong
            my @original_args = @_;
            my $params = $original_args[0] // {};

            my $args = {};
            $args->{country_code} = $params->{country} if exists $params->{country};
            $params->{token} = $params->{args}->{authorize} if !$params->{token} && $params->{args}->{authorize};
            my $token_details = BOM::RPC::v3::Utility::get_token_details($params->{token});

            if ($token_details and exists $token_details->{loginid} and $token_details->{loginid} =~ /^(\D+)\d+$/) {
                $args->{broker_code} = $1;
            }
            $params->{token_details} = $token_details;
            $args->{language}        = $params->{language} if ($params->{language});
            $args->{brand}           = $params->{brand} if ($params->{brand});

            my $r = BOM::Platform::Context::Request->new($args);
            BOM::Platform::Context::request($r);

            if (exists $params->{server_name}) {
                $params->{website_name} = BOM::RPC::v3::Utility::website_name(delete $params->{server_name});
            }

            for my $act (@$before_actions) {
                my $err;
                if ($act eq 'auth') {
                    $err = _auth($params);
                    return $err if $err;
                    next;
                }
                (($err = _auth($params)) and return $err) or next if $act eq 'auth';

                die "Error: no such hook $act" unless BOM::Transaction::Validation->can($act);

                try {
                    $err = BOM::Transaction::Validation->new({clients => [$params->{client}]})->$act($params->{client});
                }
                catch {
                    warn "Error happened when call before_action $act at method $method: $_";
                    $err = Error::Base->cuss({
                        -type              => 'Internal Error',
                        -mesg              => 'Internal Error',
                        -message_to_client => localize('Sorry, there is an internal error.'),
                    });
                };
                return BOM::RPC::v3::Utility::create_error({
                        code              => $err->get_type,
                        message_to_client => $err->{-message_to_client},
                    }) if defined $err and ref $err eq "Error::Base";

            }

            my $verify_app_res;
            if ($params->{valid_source}) {
                $params->{source} = $params->{valid_source};
            } elsif ($params->{source}) {
                $verify_app_res = BOM::RPC::v3::App::verify_app({app_id => $params->{source}});
                return $verify_app_res if $verify_app_res->{error};
            }

            my @args   = @original_args;
            my $result = try {
                $code->(@args);
            }
            catch {
                # replacing possible objects in $params with strings to avoid error in encode_json function
                my $params = {$original_args[0] ? %{$original_args[0]} : ()};
                $params->{client} = blessed($params->{client}) . ' object: ' . $params->{client}->loginid
                    if eval { $params->{client}->can('loginid') };
                defined blessed($_) and $_ = blessed($_) . ' object' for (values %$params);
                warn "Exception when handling $method - $_ with parameters " . $json->encode($params);
                BOM::RPC::v3::Utility::create_error({
                        code              => 'InternalServerError',
                        message_to_client => localize("Sorry, an error occurred while processing your account.")});
            };

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

        ['buy', \&BOM::RPC::v3::Transaction::buy, [qw(auth validate_tnc check_trade_status compliance_checks check_tax_information)]],
        [
            'buy_contract_for_multiple_accounts',
            \&BOM::RPC::v3::Transaction::buy_contract_for_multiple_accounts,
            [qw(auth validate_tnc check_trade_status compliance_checks check_tax_information)]
        ],
        ['sell', \&BOM::RPC::v3::Transaction::sell, [qw(auth validate_tnc check_trade_status compliance_checks check_tax_information)]],
        [
            'sell_contract_for_multiple_accounts',
            \&BOM::RPC::v3::Transaction::sell_contract_for_multiple_accounts,
            [qw(auth validate_tnc check_trade_status compliance_checks check_tax_information)]
        ],

        ['active_symbols', \&BOM::RPC::v3::MarketDiscovery::active_symbols],

        ['authorize', \&BOM::RPC::v3::Authorize::authorize],
        ['logout',    \&BOM::RPC::v3::Authorize::logout],

        ['get_limits', \&BOM::RPC::v3::Cashier::get_limits, [qw(auth)]],
        ['paymentagent_list',         \&BOM::RPC::v3::Cashier::paymentagent_list],
        ['paymentagent_withdraw',     \&BOM::RPC::v3::Cashier::paymentagent_withdraw, [qw(auth)]],
        ['paymentagent_transfer',     \&BOM::RPC::v3::Cashier::paymentagent_transfer, [qw(auth)]],
        ['transfer_between_accounts', \&BOM::RPC::v3::Cashier::transfer_between_accounts, [qw(auth)]],
        ['cashier',                   \&BOM::RPC::v3::Cashier::cashier, [qw(auth validate_tnc compliance_checks)]],
        ['topup_virtual',             \&BOM::RPC::v3::Cashier::topup_virtual, [qw(auth)]],

        ['payout_currencies',       \&BOM::RPC::v3::Accounts::payout_currencies],
        ['landing_company',         \&BOM::RPC::v3::Accounts::landing_company],
        ['landing_company_details', \&BOM::RPC::v3::Accounts::landing_company_details],

        ['statement',                \&BOM::RPC::v3::Accounts::statement,                [qw(auth)]],
        ['profit_table',             \&BOM::RPC::v3::Accounts::profit_table,             [qw(auth)]],
        ['get_account_status',       \&BOM::RPC::v3::Accounts::get_account_status,       [qw(auth)]],
        ['change_password',          \&BOM::RPC::v3::Accounts::change_password,          [qw(auth)]],
        ['cashier_password',         \&BOM::RPC::v3::Accounts::cashier_password,         [qw(auth)]],
        ['reset_password',           \&BOM::RPC::v3::Accounts::reset_password],
        ['get_settings',             \&BOM::RPC::v3::Accounts::get_settings,             [qw(auth)]],
        ['set_settings',             \&BOM::RPC::v3::Accounts::set_settings,             [qw(auth)]],
        ['get_self_exclusion',       \&BOM::RPC::v3::Accounts::get_self_exclusion,       [qw(auth)]],
        ['set_self_exclusion',       \&BOM::RPC::v3::Accounts::set_self_exclusion,       [qw(auth)]],
        ['balance',                  \&BOM::RPC::v3::Accounts::balance,                  [qw(auth)]],
        ['api_token',                \&BOM::RPC::v3::Accounts::api_token,                [qw(auth)]],
        ['login_history',            \&BOM::RPC::v3::Accounts::login_history,            [qw(auth)]],
        ['set_account_currency',     \&BOM::RPC::v3::Accounts::set_account_currency,     [qw(auth)]],
        ['tnc_approval',             \&BOM::RPC::v3::Accounts::tnc_approval,             [qw(auth)]],
        ['set_financial_assessment', \&BOM::RPC::v3::Accounts::set_financial_assessment, [qw(auth)]],
        ['get_financial_assessment', \&BOM::RPC::v3::Accounts::get_financial_assessment, [qw(auth)]],
        ['reality_check',            \&BOM::RPC::v3::Accounts::reality_check,            [qw(auth)]],

        ['verify_email', \&BOM::RPC::v3::NewAccount::verify_email],

        ['new_account_real',        \&BOM::RPC::v3::NewAccount::new_account_real,         [qw(auth)]],
        ['new_account_maltainvest', \&BOM::RPC::v3::NewAccount::new_account_maltainvest,  [qw(auth)]],
        ['new_account_japan',       \&BOM::RPC::v3::NewAccount::new_account_japan,        [qw(auth)]],
        ['new_account_virtual',     \&BOM::RPC::v3::NewAccount::new_account_virtual],
        ['new_sub_account',         \&BOM::RPC::v3::NewAccount::new_sub_account,          [qw(auth)]],
        ['jp_knowledge_test',       \&BOM::RPC::v3::Japan::NewAccount::jp_knowledge_test, [qw(auth)]],

        ['portfolio',              \&BOM::RPC::v3::PortfolioManagement::portfolio,              [qw(auth)]],
        ['sell_expired',           \&BOM::RPC::v3::PortfolioManagement::sell_expired,           [qw(auth)]],
        ['proposal_open_contract', \&BOM::RPC::v3::PortfolioManagement::proposal_open_contract, [qw(auth)]],

        ['app_register',       \&BOM::RPC::v3::App::register,           [qw(auth)]],
        ['app_list',           \&BOM::RPC::v3::App::list,               [qw(auth)]],
        ['app_get',            \&BOM::RPC::v3::App::get,                [qw(auth)]],
        ['app_update',         \&BOM::RPC::v3::App::update,             [qw(auth)]],
        ['app_delete',         \&BOM::RPC::v3::App::delete,             [qw(auth)]],
        ['oauth_apps',         \&BOM::RPC::v3::App::oauth_apps,         [qw(auth)]],
        ['revoke_oauth_app',   \&BOM::RPC::v3::App::revoke_oauth_app,   [qw(auth)]],
        ['app_markup_details', \&BOM::RPC::v3::App::app_markup_details, [qw(auth)]],

        ['mt5_login_list',      \&BOM::RPC::v3::MT5::Account::mt5_login_list,      [qw(auth)]],
        ['mt5_new_account',     \&BOM::RPC::v3::MT5::Account::mt5_new_account,     [qw(auth)]],
        ['mt5_get_settings',    \&BOM::RPC::v3::MT5::Account::mt5_get_settings,    [qw(auth)]],
        ['mt5_set_settings',    \&BOM::RPC::v3::MT5::Account::mt5_set_settings,    [qw(auth)]],
        ['mt5_password_check',  \&BOM::RPC::v3::MT5::Account::mt5_password_check,  [qw(auth)]],
        ['mt5_password_change', \&BOM::RPC::v3::MT5::Account::mt5_password_change, [qw(auth)]],
        ['mt5_deposit',         \&BOM::RPC::v3::MT5::Account::mt5_deposit,         [qw(auth)]],
        ['mt5_withdrawal',      \&BOM::RPC::v3::MT5::Account::mt5_withdrawal,      [qw(auth)]],

        ['copytrading_statistics', \&BOM::RPC::v3::CopyTrading::Statistics::copytrading_statistics],
        ['copy_start',             \&BOM::RPC::v3::CopyTrading::copy_start, [qw(auth)]],
        ['copy_stop',              \&BOM::RPC::v3::CopyTrading::copy_stop, [qw(auth)]],

        ['document_upload', \&BOM::RPC::v3::DocumentUpload::upload, [qw(auth)]],
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
    my $vsz_start;

    $app->hook(
        before_dispatch => sub {
            my $c = shift;
            $cpu  = Proc::CPUUsage->new();
            $call = $c->req->url->path;
            $0    = "bom-rpc: " . $call;     ## no critic (RequireLocalizedPunctuationVars)
            $call =~ s/\///;
            $request_start = [Time::HiRes::gettimeofday];
            DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.call.count', {tags => ["rpc:$call"]});
            $vsz_start = current_vsz();
            BOM::Test::Time::set_date_from_file() if defined $INC{'BOM/Test/Time.pm'};    # check BOM::Test::Time for details
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

            # Track whether we have any change in memory usage
            my $vsz_increase = current_vsz() - $vsz_start;
            # Anything more than 100 MB is probably something we should know about,
            # residence_list and ticks can take >64MB so we can't have this limit set
            # too low.
            warn sprintf "Large VSZ increase for %d - %d bytes, %s\n", $$, $vsz_increase, $call if $vsz_increase > (100 * 1024 * 1024);
            # We use timing for the extra statistics (min/max/avg) it provides
            DataDog::DogStatsd::Helper::stats_timing('bom_rpc.v_3.vsz.increase', $vsz_increase, {tags => ["rpc:$call"]});

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

            $0 = "bom-rpc: (idle since $end #req=$request_counter us=$usage%)";    ## no critic (RequireLocalizedPunctuationVars)
        });

    # set $0 after forking children
    Mojo::IOLoop->timer(0, sub { @recent = [[Time::HiRes::gettimeofday], 0]; $0 = "bom-rpc: (new)" });  ## no critic (RequireLocalizedPunctuationVars)

    return;
}

=head2 current_vsz

Returns the VSZ (virtual memory usage) for the current process, in bytes.

=cut

sub current_vsz {
    my $stat = path("/proc/self/stat")->slurp_utf8;
    # Process name is awkward and can contain (). We know that we're a running process.
    $stat =~ s/^.*\) R [0-9]+ //;
    return +(split " ", $stat)[18];
}

1;
