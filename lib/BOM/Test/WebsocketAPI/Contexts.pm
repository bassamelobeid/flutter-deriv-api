package BOM::Test::WebsocketAPI::Contexts;

no indirect;

use strict;
use warnings;

=head1 NAME

BOM::Test::WebsocketAPI::Contexts - To extend the Devops::BinaryAPI::Contexts

=head1 DESCRIPTION

Extends the functionality of C<Devops::BinaryAPI::Contexts>

=head2

=cut

use curry;
use IO::Async::Process;

use Devops::BinaryAPI::Tester::DSL;

=head2 restart_redis

Returns a C<Future> which is C<done> once the redis restarted successfully.

    ->restart_redis
    ->take_latest

=cut

context restart_redis => sub {
    my ($self) = @_;

    $self->{completed} = $self->completed->then(
        $self->$curry::weak(
            sub {
                shift->suite->tester->publisher->redis->then(
                    sub {
                        shift->client_kill('SKIPME', 'no');
                    });
            }));

    return $self;
};

1;
