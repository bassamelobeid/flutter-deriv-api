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
use BOM::Test::WebsocketAPI::Redis qw/shared_redis ws_redis_master/;
use Future::Utils qw(fmap_void);

=head2 restart_redis

Returns a C<Future> which is C<done> once the redis restarted successfully.

    ->restart_redis
    ->take_latest

=cut

context restart_redis => sub {
    my ($self) = @_;

    $self->{completed} = $self->completed->then(
        sub {
            Future->needs_all(
                map {
                    $_->then(sub { shift->client_kill('SKIPME', 'no') })
                } (shared_redis(), ws_redis_master()));
        });

    return $self;
};

context pause_publish => sub {
    my ($self, $method) = @_;

    $self->completed->on_done(
        $self->$curry::weak(
            sub {
                shift->suite->tester->publisher->pause($method);
            }));

    return $self;
};

context resume_publish => sub {
    my ($self, $method) = @_;

    $self->completed->on_done(
        $self->$curry::weak(
            sub {
                shift->suite->tester->publisher->resume($method);
            }));

    return $self;
};

context skip_until_publish_paused => sub {
    my ($self, $method) = @_;

    my $take_f = $self->source->skip_until(
        $self->$curry::weak(
            sub {
                shift->suite->tester->publisher->is_paused($method);
            }))->first->completed;

    $self->{completed} = $self->completed->then(sub { $take_f });

    return $self;
};

1;
