package BOM::RPC;

use strict;
use warnings;
no indirect;

use Mojo::Base 'Mojolicious';
use Mojo::IOLoop;
use MojoX::JSON::RPC::Service;
use IO::Async::Loop::Mojo;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Proc::CPUUsage;
use Time::HiRes;
use Try::Tiny;
use Path::Tiny;
use JSON::MaybeXS;
use Scalar::Util q(blessed);

use BOM::Platform::Context qw(localize);
use BOM::Platform::Context::Request;
use BOM::RPC::Registry;
use BOM::User::Client;
use BOM::Database::Rose::DB;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Static;
use BOM::RPC::v3::TickStreamer;
use BOM::RPC::v3::Transaction;
use BOM::RPC::v3::MarketDiscovery;
use BOM::RPC::v3::Authorize;
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::NewAccount;
use BOM::RPC::v3::Contract;
use BOM::RPC::v3::PortfolioManagement;
use BOM::RPC::v3::App;
use BOM::RPC::v3::MT5::Account;
use BOM::RPC::v3::CopyTrading::Statistics;
use BOM::RPC::v3::CopyTrading;
use BOM::Transaction::Validation;
use BOM::RPC::v3::DocumentUpload;
use BOM::RPC::v3::Pricing;
use BOM::RPC::v3::MarketData;

use constant REQUEST_ARGUMENTS_TO_BE_IGNORED => qw (req_id passthrough);

# TODO(leonerd): this one RPC is unusual, coming from Utility.pm which doesn't
# contain any other RPCs
BOM::RPC::Registry::register(longcode => \&BOM::RPC::v3::Utility::longcode);

my $json = JSON::MaybeXS->new;

# This has a side-effect of setting the IO::Async::Loop singleton.
# Once we drop Mojolicious, this line can be removed.
my $loop = IO::Async::Loop::Mojo->new;
{
    my $loop_check = IO::Async::Loop->new;
    die 'Unexpected event loop class: had '
        . ref($loop) . ' and '
        . ref($loop_check)
        . ' from magic constructor for IO::Async, expected a subclass of IO::Async::Loop::Mojo'
        unless $loop->isa('IO::Async::Loop::Mojo')
        and $loop_check->isa('IO::Async::Loop::Mojo');
}

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

sub set_current_context {
    my ($params) = @_;

    my $args = {};
    $args->{country_code} = $params->{country}  if exists $params->{country};
    $args->{language}     = $params->{language} if $params->{language};
    $args->{brand}        = $params->{brand}    if $params->{brand};

    my $token_details = $params->{token_details};
    if ($token_details and exists $token_details->{loginid} and $token_details->{loginid} =~ /^(\D+)\d+$/) {
        $args->{broker_code} = $1;
    }

    my $r = BOM::Platform::Context::Request->new($args);
    BOM::Platform::Context::request($r);

    return;
}

=head2 wrap_rpc_sub

    $code = wrap_rpc_sub($def)

    $result = $code->(@args)

Given a single service definition for one RPC method, returns a C<CODE>
reference for invoking it. The returned function executes synchronously,
eventually returning the result of the RPC, even for asynchronous methods.

=cut

# TODO(leonerd): Allow this to be async-returning for Futures

sub wrap_rpc_sub {
    my ($def) = @_;

    my $method = $def->name;

    return sub {
        my @original_args = @_;
        my $params = $original_args[0] // {};

        $params->{token} = $params->{args}->{authorize} if !$params->{token} && $params->{args}->{authorize};

        foreach (REQUEST_ARGUMENTS_TO_BE_IGNORED) {
            delete $params->{args}{$_};
        }

        $params->{token_details} = BOM::RPC::v3::Utility::get_token_details($params->{token});

        set_current_context($params);

        if (exists $params->{server_name}) {
            $params->{website_name} = BOM::RPC::v3::Utility::website_name(delete $params->{server_name});
        }

        my $verify_app_res;
        if ($params->{valid_source}) {
            $params->{source} = $params->{valid_source};
        } elsif ($params->{source}) {
            $verify_app_res = BOM::RPC::v3::App::verify_app({app_id => $params->{source}});
            return $verify_app_res if $verify_app_res->{error};
        }

        if ($def->is_auth) {
            if (my $client = $params->{client}) {
                # If there is a $client object but is not a Valid BOM::User::Client we return an error
                unless (blessed $client && $client->isa('BOM::User::Client')) {
                    return BOM::RPC::v3::Utility::create_error({
                            code              => 'InvalidRequest',
                            message_to_client => localize("Invalid request.")});
                }
            } else {
                # If there is no $client, we continue with our auth check
                my $token_details = $params->{token_details};
                return BOM::RPC::v3::Utility::invalid_token_error()
                    unless $token_details and exists $token_details->{loginid};

                my $client = BOM::User::Client->new({loginid => $token_details->{loginid}});

                if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
                    return $auth_error;
                }

                $params->{client} = $client;
                $params->{app_id} = $token_details->{app_id};
            }
        }

        my @args   = @original_args;
        my $result = try {
            my $code = $def->code;
            if ($def->is_async) {
                $code->(@args)->get;
            } else {
                $code->(@args);
            }
        }
        catch {
            # replacing possible objects in $params with strings to avoid error in encode_json function
            my $params = {$original_args[0] ? %{$original_args[0]} : ()};
            $params->{client} = blessed($params->{client}) . ' object: ' . $params->{client}->loginid
                if eval { $params->{client}->can('loginid') };

            my $error = "Exception when handling $method" . (defined $params->{client} ? " for $params->{client}." : '.');
            $error .= " $_" if ($ENV{LOG_DETAILED_EXCEPTION});
            warn $error;

            BOM::RPC::v3::Utility::create_error({
                    code              => 'InternalServerError',
                    message_to_client => localize("Sorry, an error occurred while processing your request.")});
        };

        if ($verify_app_res && ref $result eq 'HASH' && !$result->{error}) {
            $result->{stash} = {%{$result->{stash} // {}}, %{$verify_app_res->{stash}}};
        }
        return $result;
    };
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

    # get flag to log detailed exception
    ## no critic (RequireLocalizedPunctuationVars)
    $ENV{LOG_DETAILED_EXCEPTION} = $app->config->{hypnotoad}->{log_detailed_exception};

    my $log = $app->log;

    my $signature = "Binary.com RPC";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    apply_usergroup $app->config->{hypnotoad}, sub {
        $log->info(@_);
    };

    my %services = map {
        my $method = $_->name;
        "/$method" => MojoX::JSON::RPC::Service->new->register($method, wrap_rpc_sub($_));
    } BOM::RPC::Registry::get_service_defs();

    $app->plugin(
        'json_rpc_dispatcher' => {
            services          => \%services,
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
    my $on_production = $ENV{TEST_DATABASE} ? 0 : 1;

    $app->hook(
        before_dispatch => sub {
            my $c = shift;
            $cpu  = Proc::CPUUsage->new();
            $call = $c->req->url->path;
            $0    = "bom-rpc: " . $call if $on_production;    ## no critic (RequireLocalizedPunctuationVars)
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

            $0 = "bom-rpc: (idle since $end #req=$request_counter us=$usage%)" if $on_production;    ## no critic (RequireLocalizedPunctuationVars)
        });

    # set $0 after forking children
    Mojo::IOLoop->timer(0, sub { @recent = [[Time::HiRes::gettimeofday], 0]; $0 = "bom-rpc: (new)" })   ## no critic (RequireLocalizedPunctuationVars)
        if $on_production;

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
