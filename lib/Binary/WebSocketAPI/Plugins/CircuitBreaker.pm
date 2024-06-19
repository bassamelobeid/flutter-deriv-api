package Binary::WebSocketAPI::Plugins::CircuitBreaker;

use strict;
use warnings;

=head1 NAME

Binary::WebSocketAPI::Plugins::CircuitBreaker - A module for managing circuit breaker pattern


=head1 DESCRIPTION

The Binary::WebSocketAPI::Plugins::CircuitBreaker module provides a simplified implementation of the circuit breaker pattern.
For now the control of the circuit state is based on the website status, the circuit is initially closed and will be opened if the website status is down.

=cut

use curry;
use Mojo::Base 'Mojolicious::Plugin';
use Future::Mojo;
use Log::Any qw($log);
use Binary::WebSocketAPI::SiteStatusMonitor;

# These methods are used to check the health of the server and to communicate with the FE if the server is up or down
use constant EXCLUDED_METHODS => {
    website_status => 1,
    ping           => 1
};

=head2 register

Register the plugin in the application and add the circuit_breaker helper

=cut

sub register {
    my ($self, $app) = @_;

    $self->{site_status_monitor} = Binary::WebSocketAPI::SiteStatusMonitor->new();
    # Circuit is initially closed
    $self->{circuit_state} = {
        closed => 1,
        open   => 0,
    };

    $app->helper(circuit_breaker => $self->curry::_circuit_breaker);

    return;
}

=head2 _circuit_breaker

The circuit breaker helper is called on every request to check the circuit state

=over 4

=item * C<$c> - websocket connection object

=item * C<$call_name> string - name of the API call

=back

Returns Future object. Future object will be done if succeed, fail otherwise.

=cut

sub _circuit_breaker {
    my ($self, $c, $call_name) = @_;

    $self->_circuit_state_controller();

    if (!EXCLUDED_METHODS->{$call_name} && $self->{circuit_state}->{open}) {
        my $message = $c->l(
            'The server is currently unable to handle the request due to a temporary overload or maintenance of the server. Please try again later.');
        my $err_resp = $c->new_error($call_name, 'ServiceUnavailable', $message);
        return Future->fail($err_resp);
    }

    return Future->done();
}

=head2 _circuit_state_controller

The circuit state controller is responsible for updating the circuit state and should be called at the start of every request to the circuit breaker

=cut

sub _circuit_state_controller {
    my $self           = shift;
    my $website_status = $self->{site_status_monitor}->site_status;

    $self->{circuit_state} = {
        closed => $website_status ne 'down',
        open   => $website_status eq 'down',
    };

    return $self->{circuit_state};
}

1;

