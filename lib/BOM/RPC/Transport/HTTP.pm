package BOM::RPC::Transport::HTTP;

use strict;
use warnings;
no indirect;

use Mojo::Base 'Mojolicious';
use Mojo::IOLoop;
use MojoX::JSON::RPC::Service;
use IO::Async::Loop::Mojo;

use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Path::Tiny;
use Proc::CPUUsage;
use Time::HiRes;

use BOM::RPC ();
use BOM::RPC::Registry;

# This has a side-effect of setting the IO::Async::Loop singleton.
# Once we drop Mojolicious, this line can be removed.
local $ENV{IO_ASYNC_LOOP} = 'IO::Async::Loop::Mojo'; 
my $loop = IO::Async::Loop->new;
{
    my $loop_check = IO::Async::Loop->new;
    die 'Unexpected event loop class: had '
        . ref($loop) . ' and '
        . ref($loop_check)
        . ' from magic constructor for IO::Async, expected a subclass of IO::Async::Loop::Mojo'
        unless $loop->isa('IO::Async::Loop::Mojo')
        and $loop_check->isa('IO::Async::Loop::Mojo');
}

=head2 apply_usergroup

    apply_usergroup($params, $log)

If the process is running as root (UID 0), switches the real and effective
user and group IDs to the C<user> and C<group> keys in the hash referred to by
$params.

=cut

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

=head2 startup

Implements the body of Mojolicious app

=cut

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
        "/$method" => MojoX::JSON::RPC::Service->new->register($method, BOM::RPC::wrap_rpc_sub($_));
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

    $vsz = current_vsz()

Returns the VSZ (virtual memory usage) for the current process, in bytes.

=cut

sub current_vsz {
    my $stat = path("/proc/self/stat")->slurp_utf8;
    # Process name is awkward and can contain (). We know that we're a running process.
    $stat =~ s/^.*\) R [0-9]+ //;
    return +(split " ", $stat)[18];
}

1;
