package BOM::Test::WebsocketAPI;

no indirect;

use strict;
use warnings;

=head1 NAME

BOM::Test::WebsocketAPI - extends C<Devops::BinaryAPI::Tester> for writing tests
that will run on QA boxes

=head1 SYNOPSIS

 my $loop = IO::Async::Loop->new;
 $loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(%options)
 );
 $tester->publish(tick => [qw(R_100)]);
 $tester->run->get;
 done_testing;

=head1 DESCRIPTION

Most of the functionality inherits from C<Devops::BinaryAPI::Tester>.

This class will create an in-process instance of the Binary WebsocketAPI server
for tests to run against. It also creates a temporary Redis instance into which
we can simulate subscription events to be received by tests.

Generally, tests using the class will be run under prove with a .proverc that
sets up other parts of the test environment, e.g. temporary RPC server.

=cut

use parent qw(Devops::BinaryAPI::Tester);

use Net::Async::Redis;
use Log::Any qw($log);
use List::Util qw(shuffle);
use curry;
use Test::More;
use feature 'state';

use Module::Load ();
# Load All modules under these paths
# See Devops::BinaryAPI::Tester
use Module::Pluggable search_path =>
    ['BOM::Test::WebsocketAPI::Contexts', 'BOM::Test::WebsocketAPI::Helpers', 'BOM::Test::WebsocketAPI::Tests', 'BOM::Test::WebsocketAPI::Template'];

Module::Load::load($_) for sort __PACKAGE__->plugins;

use Binary::API::Mapping::Response;

BEGIN {
    our $mojo_accept = \&Mojo::IOLoop::Server::_accept;
    require Binary::WebSocketAPI;
    {
        no warnings 'redefine';    ## no critic
        *Mojo::IOLoop::Server::_accept = $mojo_accept;
    }
    Binary::WebSocketAPI->import();
}
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper qw/launch_redis/;
use BOM::Test::WebsocketAPI::Contexts;
use BOM::Test::WebsocketAPI::SanityChecker;
use BOM::Test::WebsocketAPI::Publisher;
use BOM::Test::WebsocketAPI::MockRPC;

my $default_suite_params = {
    requests => [],
};

sub configure {
    my ($self, %args) = @_;
    for my $k (qw( max_response_delay skip_sanity_checks ws_log_level suite_params)) {
        $self->{$k} = delete $args{$k} if exists $args{$k};
    }
    return $self->next::method(%args);
}

sub _add_to_loop {
    my ($self) = @_;

    # Start publisher
    return $self->publisher;
}

=head1 ACCESSORS

=head2 app_id

Override the default app_id of C<Devops::BinaryAPI::Tester>

=cut

sub app_id { return shift->{app_id} // 1 }

=head2 max_response_delay

The maximum delay allowed between publishing a message to Redis
and receiving it in the API responses.

=cut

sub max_response_delay {
    return shift->{max_response_delay} // 0.15;    # sec
}

=head2 skip_sanity_checks

Accepts a C<hashref>, will selectively skip the sanity checks.

    {
        balance => ['check_duplicates'],
    }

Used to skip checks selectively when there's a bug in the API and it's causing
the test result to be noisy.

=cut

sub skip_sanity_checks { return shift->{skip_sanity_checks} // {} }

=head2 suite_responses

List of C<suite> responses kept for doing sanity checks after the C<suite> is
C<completed>.

=cut

sub suite_responses { return shift->{suite_responses} //= {} }

=head2 ws_log_level

Set the websocket log level (same as C<Mojo::Log> levels, default is C<error>.

=cut

sub ws_log_level { return shift->{ws_log_level} //= 'error' }

=head2 port

Launches master websocket redis server and keeps it object in a state variable.

=cut

sub load_ws_redis_server {
    # A cache that keeps the test ws redis server instance.
    state $ws_redis_server;

    unless ($ws_redis_server) {
        my ($path, $server) = launch_redis();
        $ws_redis_server = {
            path   => $path,
            server => $server
        };
    }

    return;
}

=head2 port

Creates the Binary WebsocketAPI instance on demand and returns the used C<port>.

=cut

sub port {
    my ($self) = @_;

    return $self->{port} if exists $self->{port};

    ## no critic (RequireLocalizedPunctuationVars)
    $ENV{BOM_TEST_RATE_LIMITATIONS} = '/home/git/regentmarkets/bom-test/lib/BOM/Test/WebsocketAPI/' . 'rate_limitations.yml';

    load_ws_redis_server();

    my $binary = Binary::WebSocketAPI->new();
    $binary->log->level($self->ws_log_level);
    $self->{daemon} = Mojo::Server::Daemon->new(
        app    => $binary,
        listen => ["http://127.0.0.1"]);
    $self->{daemon}->start;

    return $self->{port} //= $self->{daemon}->ports->[0];
}

=head2 endpoint

If not set via new(), a WebSocketAPI instance will be created and its endpoint
returned.

=cut

sub endpoint {
    my ($self) = @_;

    return $self->{endpoint} if exists $self->{endpoint};

    return $self->{endpoint} = $ENV{WS_TEST_ENDPOINT} // "ws://127.0.0.1:" . $self->port;
}

=head2 publisher

Returns a C<publisher> instance, which is used for publishing values to Redis
and DB.

=cut

sub publisher {
    my $self = shift;

    return $self->{publisher} if exists $self->{publisher};

    $self->{publisher} = BOM::Test::WebsocketAPI::Publisher->new;

    $self->add_child($self->{publisher}) unless $self->{publisher}->loop;

    return $self->{publisher};
}

=head2 sanity_checker

Returns an existing or create a new C<BOM::Test::WebsocketAPI::SanityChecker>for
sanity checking API responses.

=cut

sub sanity_checker {
    my ($self) = @_;
    return $self->{sanity_checker} //= BOM::Test::WebsocketAPI::SanityChecker->new($self);
}

sub suite_params {
    my ($self) = @_;

    $self->{suite_params} //= {};

    return {$default_suite_params->%*, $self->{suite_params}->%*,};
}

=head1 METHODS

=head2 new_suite

Overrides new_suite in the parent to add more checks

=cut

sub new_suite {
    my ($self) = @_;

    my $suite = $self->next::method;

    return $suite->on_completed(
        $self->$curry::weak(
            sub {
                my ($self, $suite, $name) = @_;
                $self->suite_responses->{$name} = $suite->responses;
            }));
}

=head2 call

Overrides the parent call to add default parameters

=cut

sub call {
    my ($self, $method, %args) = @_;

    my $suite_params = $self->suite_params;
    $args{$_} //= $suite_params->{$_} for keys $suite_params->%*;

    return $self->next::method($method, %args);
}

sub run_sanity_checks {
    my ($self, $to_skip) = @_;

    for my $name (keys $self->suite_responses->%*) {
        subtest "Sanity Checks for suite: $name" => sub {
            ok $self->sanity_checker->check($self->suite_responses->{$name}, $to_skip // $self->skip_sanity_checks,),
                'Sanity checks were successfully done';
        };
    }

    return;
}

# Suppress global destruction warnings
$SIG{__WARN__} = sub { warn $_[0] unless $_[0] =~ /global destruction/ };    ## no critic (Variables::RequireLocalizedPunctuationVars)

1;
