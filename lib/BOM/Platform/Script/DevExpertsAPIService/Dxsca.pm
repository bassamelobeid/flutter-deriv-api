package BOM::Platform::Script::DevExpertsAPIService::Dxsca;

use strict;
use warnings;

use parent qw(BOM::Platform::Script::DevExpertsAPIService);

use Future;
use Future::AsyncAwait;
use Syntax::Keyword::Try;
use Socket qw(IPPROTO_TCP);
use WebService::Async::DevExperts::Dxsca::Client;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);

use Log::Any qw($log);

# seconds before token expiry that session token will be renewed
use constant TOKEN_RENEW_SECS => 60;

=head1 NAME

DevExperts API DXSCA Service

=head1 DESCRIPTION

Provides an HTTP interface to DevExperts DXSCA API wrapper.

=cut

=head2 configure

Apply configuration from new().

See base class for supported parameters.

=cut

sub configure {
    my ($self, %args) = @_;

    $self->{datadog_prefix} = 'devexperts.dxsca_api_service.';

    return $self->next::method(%args);
}

=head2 _add_to_loop

Called when we are added to loop. Creates http server and API client.

=cut

sub _add_to_loop {
    my ($self) = @_;

    $self->add_child(
        $self->{clients}{demo} = WebService::Async::DevExperts::Dxsca::Client->new(
            host => $self->{demo_host},
            port => $self->{demo_port},
            user => $self->{demo_user},
            pass => $self->{demo_pass},
        ));

    $self->add_child(
        $self->{clients}{real} = WebService::Async::DevExperts::Dxsca::Client->new(
            host => $self->{real_host},
            port => $self->{real_port},
            user => $self->{real_user},
            pass => $self->{real_pass},
        ));

    return $self->next::method;
}

1;
