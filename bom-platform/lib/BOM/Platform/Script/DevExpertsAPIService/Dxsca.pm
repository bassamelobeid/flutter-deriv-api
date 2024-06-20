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
            host   => $self->{demo_host},
            port   => $self->{demo_port},
            user   => $self->{demo_user},
            pass   => $self->{demo_pass},
            server => 'demo',
        ));

    $self->add_child(
        $self->{clients}{real} = WebService::Async::DevExperts::Dxsca::Client->new(
            host   => $self->{real_host},
            port   => $self->{real_port},
            user   => $self->{real_user},
            pass   => $self->{real_pass},
            server => 'real',
        ));

    return $self->next::method;
}

=head2 call_api

Overrides base class to handle login. 

=cut

async sub call_api {
    my ($self, $server, $method, $params) = @_;

    if ($method ne 'login') {
        my $client = $self->{clients}{$server};
        # Automatically login if no session, or session is about to expire. The token is stored in $client.
        if (not $client->session_expiry or ($client->session_expiry - TOKEN_RENEW_SECS) < time) {
            $log->tracef('No token or token expired, logging in.');
            await $self->next::method(
                $server, 'login',
                {
                    username => $self->{$server . '_username'},
                    domain   => $self->{$server . '_domain'},
                    password => $self->{$server . '_pass'},
                });
        }
    }

    return await $self->next::method($server, $method, $params);
}

1;
