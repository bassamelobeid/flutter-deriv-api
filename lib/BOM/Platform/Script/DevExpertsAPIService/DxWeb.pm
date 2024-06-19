package BOM::Platform::Script::DevExpertsAPIService::DxWeb;

use strict;
use warnings;

use parent qw(BOM::Platform::Script::DevExpertsAPIService);

use Future;
use Future::AsyncAwait;
use Syntax::Keyword::Try;
use Socket qw(IPPROTO_TCP);
use WebService::Async::DevExperts::DxWeb::Client;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);

use Log::Any qw($log);

$Future::TIMES = 1;

# seconds between heartbeat requests
use constant HEARTBEAT_INVERVAL => 60;

=head1 NAME

DevExperts API DxWeb Service

=head1 DESCRIPTION

Provides an HTTP interface to DevExperts DXWeb API wrapper.

=cut

=head2 configure

Apply configuration from new().

See base class for supported parameters.

=cut

sub configure {
    my ($self, %args) = @_;

    for (qw()) {
        $self->{$_} = delete $args{$_};
    }
    $self->{datadog_prefix} = 'devexperts.api_service.';

    return $self->next::method(%args);
}

=head2 _add_to_loop

Called when we are added to loop. Creates http server and API client.

=cut

sub _add_to_loop {
    my ($self) = @_;

    $self->add_child(
        $self->{clients}{demo} = WebService::Async::DevExperts::DxWeb::Client->new(
            host                => $self->{demo_host},
            port                => $self->{demo_port},
            user                => $self->{demo_user},
            pass                => $self->{demo_pass},
            close_after_request => $self->{close_after_request},
            connections         => $self->{connections},
            timeout             => $self->{timeout},
        ));

    $self->add_child(
        $self->{clients}{real} = WebService::Async::DevExperts::DxWeb::Client->new(
            host                => $self->{real_host},
            port                => $self->{real_port},
            user                => $self->{real_user},
            pass                => $self->{real_pass},
            connections         => $self->{connections},
            timeout             => $self->{timeout},
            close_after_request => $self->{close_after_request},
        ));

    $self->add_child(
        $self->{heartbeat} = IO::Async::Timer::Periodic->new(
            interval => HEARTBEAT_INVERVAL,
            on_tick  => $self->$curry::weak(sub { shift->do_heartbeat->retain }),
        ));
    $self->{heartbeat}->start;

    return $self->next::method;
}

=head2 do_heartbeat

Sends simple server request and ping and sends metrics to Datadog.

=cut

async sub do_heartbeat {
    my ($self) = @_;
    my (@calls, @pings);

    for my $server ('real', 'demo') {
        push @pings,
            $self->loop->connect(
            host     => $self->{$server . '_host_base'},
            service  => $self->{$server . '_port'},
            protocol => IPPROTO_TCP,
        )->set_label($server);
    }

    my @ping_fs = await Future->wait_all(@pings);
    for my $f (@ping_fs) {
        stats_timing($self->{datadog_prefix} . 'ping', 1000 * $f->elapsed, {tags => ['server:' . $f->label]}) unless ($f->is_failed);
        $log->debugf('ping failed for %s: %s', $f->label, $f->failure) if $f->is_failed;
    }

    for my $server ('real', 'demo') {
        push @calls, $self->{clients}{$server}->broker_get(broker_code => 'root_broker')->set_label($server);
    }

    my @call_fs = await Future->wait_all(@calls);
    for my $f (@call_fs) {
        stats_inc($self->{datadog_prefix} . 'heartbeat', {tags => ['server:' . $f->label]}) unless ($f->is_failed);
        $log->debugf('heartbeat failed for %s: %s', $f->label, $f->failure) if $f->is_failed;
    }
}

1;
