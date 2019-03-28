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

use Binary::API::Mapping::Response;
use Binary::WebSocketAPI;
use BOM::Test::RPC::BomRpc;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client qw(create_client);
use BOM::Database::Model::OAuth;
use BOM::User;
use BOM::Test::WebsocketAPI::Contexts;
use BOM::Test::WebsocketAPI::SanityChecker;
use BOM::Test::WebsocketAPI::Publisher;

use Module::Load ();
# Load All modules under these paths
# See Devops::BinaryAPI::Tester
use Module::Pluggable search_path => ['BOM::Test::WebsocketAPI::Contexts', 'BOM::Test::WebsocketAPI::Helpers', 'BOM::Test::WebsocketAPI::Tests',];

Module::Load::load($_) for sort __PACKAGE__->plugins;

sub configure {
    my ($self, %args) = @_;
    for my $k (qw(
        max_response_delay
        skip_sanity_checks
        ws_debug
        ticks_history_count
        sanity_checks_when_suite_completed
        ))
    {
        $self->{$k} = delete $args{$k} if exists $args{$k};
    }
    return $self->next::method(%args);
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

=head2 ticks_history_count

Number of ticks history to generate for testing, default: 1000

=cut

sub ticks_history_count {
    return shift->{ticks_history_count} // 1000;
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

=head2 sanity_checks_when_suite_completed

If set the sanity checks won't run after each C<suite> is C<completed>.

=cut

sub sanity_checks_when_suite_completed { return shift->{sanity_checks_when_suite_completed} // 0 }

=head2 suite_responses

List of C<suite> responses kept for doing sanity checks after the C<suite> is
C<completed>.

=cut

sub suite_responses { return shift->{suite_responses} //= {} }

=head2 ws_debug

If set to C<1>, websocket debug output will be printed in test output

=cut

sub ws_debug { return shift->{ws_debug} // 0 }

=head2 port

Creates the Binary WebsocketAPI instance on demand and returns the used C<port>.

=cut

sub port {
    my ($self) = @_;

    return $self->{port} if exists $self->{port};

    ## no critic (RequireLocalizedPunctuationVars)
    $ENV{BOM_TEST_RATE_LIMITATIONS} = '/home/git/regentmarkets/bom-test/lib/BOM/Test/WebsocketAPI/' . 'rate_limitations.yml';

    my $binary = Binary::WebSocketAPI->new();
    $binary->log(Mojo::Log->new(level => 'debug')) if $self->ws_debug;
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

=head2 new_client

Create a new binary user with a token.

=cut

sub new_client {
    my ($self) = @_;

    my $new_client = create_client;

    my $email = join('', shuffle(split('', 'binarybinarybinary'))) . '@binary.com';
    $new_client->email($email);
    $new_client->save;

    # For some reason needed, transaction subscription never happens if not done
    $new_client->account('USD');

    my $loginid = $new_client->loginid;
    my $user    = BOM::User->create(
        email    => $email,
        password => 'Very strong password this is',
    );
    $user->add_client($new_client);

    $new_client->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    $new_client->payment_legacy_payment(
        currency     => 'USD',
        amount       => 10000,
        payment_type => 'free_gift',
        remark       => 'A generous gift to our test client',
    );

    return $new_client;
}

=head2 publisher

Returns a C<publisher> instance, which is used for publishing values to Redis
and DB.

=cut

sub publisher {
    my $self = shift;

    return $self->{publisher} if exists $self->{publisher};

    $self->{publisher} = BOM::Test::WebsocketAPI::Publisher->new(ticks_history_count => $self->ticks_history_count);

    $self->loop->add($self->{publisher}) unless $self->{publisher}->loop;

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

=head1 METHODS

=head2 publish

Start publishing a group of requests

    $tester->publish(
        transaction => [{
            account_id => ...
        }],
        tick => [...]);

returns a list of published values for all requests

=cut

sub publish {
    my ($self, %requests) = @_;

    return [map { $self->publisher->$_($requests{$_}->@*) } keys %requests];
}

=head2 new_suite

Overrides new_suite in the parent to add more checks

=cut

sub new_suite {
    my ($self) = @_;

    my $suite = $self->next::method;

    if ($self->sanity_checks_when_suite_completed) {
        return $suite->on_completed(
            $self->$curry::weak(
                sub {
                    my ($self, $suite) = @_;

                    subtest 'Sanity Checks' => sub {
                        ok $self->sanity_checker->check($suite->responses, $self->skip_sanity_checks,), 'Sanity checks were successfully done';
                    };
                }));
    }
    return $suite->on_completed(
        $self->$curry::weak(
            sub {
                my ($self, $suite, $name) = @_;
                $self->suite_responses->{$name} = $suite->responses;
            }));
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

1;
