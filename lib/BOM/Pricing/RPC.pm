package BOM::Pricing::RPC;

use Mojo::Base 'Mojolicious';
use Mojo::IOLoop;
use MojoX::JSON::RPC::Service;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Proc::CPUUsage;
use Time::HiRes;
use Try::Tiny;
use Carp qw(cluck);

use BOM::Platform::Context qw(localize);
use BOM::Platform::Context::Request;
use BOM::Pricing::v3::Contract;

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
            my $args = {};
            $args->{language} = $params->{language} if ($params->{language});
            my $r = BOM::Platform::Context::Request->new($args);
            BOM::Platform::Context::request($r);
            return $code->(@_);
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
    $app->plugin('Config' => {file => $ENV{RPC_CONFIG} || '/etc/rmg/pricing_rpc.conf'});

    # hard-wire this here. A worker of this service is supposed to handle only
    # one request at a time. Hence, it must also C<accept> only one connection
    # at a time.
    $app->config->{hypnotoad}->{multi_accept} = 1;

    # A connection should accept only one requests, then it should terminate.
    $app->config->{hypnotoad}->{requests} = 1;

    my $log = $app->log;

    my $signature = "Binary.com Pricing RPC";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    apply_usergroup $app->config->{hypnotoad}, sub {
        $log->info(@_);
    };

    my @services = (
        ['send_ask',             \&BOM::Pricing::v3::Contract::send_ask],
        ['send_multiple_ask',    \&BOM::Pricing::v3::Contract::send_multiple_ask],
        ['get_bid',              \&BOM::Pricing::v3::Contract::get_bid],
        ['get_contract_details', \&BOM::Pricing::v3::Contract::get_contract_details],
        ['contracts_for',        \&BOM::Pricing::v3::Contract::contracts_for],
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
                DataDog::DogStatsd::Helper::stats_inc('bom_pricing_rpc.v_3.call_failure.count', {tags => ["rpc:$path"]});
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
            $0    = "bom-pricing-rpc: " . $call;    ## no critic
            $call =~ s/\///;
            $request_start = [Time::HiRes::gettimeofday];
            DataDog::DogStatsd::Helper::stats_inc('bom_pricing_rpc.v_3.call.count', {tags => ["rpc:$call"]});
        });

    $app->hook(
        after_dispatch => sub {
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

            DataDog::DogStatsd::Helper::stats_inc('bom_pricing_rpc.v_3.call_success.count', {tags => ["rpc:$call"]});
            DataDog::DogStatsd::Helper::stats_timing(
                'bom_pricing_rpc.v_3.call.timing',
                (1000 * Time::HiRes::tv_interval($request_start)),
                {tags => ["rpc:$call"]});
            DataDog::DogStatsd::Helper::stats_timing('bom_pricing_rpc.v_3.cpuusage', $cpu->usage(), {tags => ["rpc:$call"]});

            push @recent, [$request_start, Time::HiRes::tv_interval($request_end, $request_start)];
            shift @recent if @recent > 50;

            my $usage = 0;
            $usage += $_->[1] for @recent;
            $usage = sprintf('%.2f', 100 * $usage / Time::HiRes::tv_interval($request_end, $recent[0]->[0]));

            $0 = "bom-pricing-rpc: (idle since $end #req=$request_counter us=$usage%)";    ## no critic
        });

    # set $0 after forking children
    Mojo::IOLoop->timer(0, sub { @recent = [[Time::HiRes::gettimeofday], 0]; $0 = "bom-pricing-rpc: (new)" });    ## no critic

    return;
}

1;
