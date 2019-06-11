package BOM::RPC::v3::Services;

=head1 NAME

BOM::RPC::v3::Services - Construct required service objects

=head1 DESCRIPTION

This is helper to create service object required for requesting data from
various sources.

=cut

use strict;
use warnings;
use feature 'state';

use parent qw(IO::Async::Notifier);

use WebService::Async::Onfido;

use BOM::Config;
use BOM::RPC::v3::Services::Onfido;

sub new {
    my ($class) = @_;

    state $instance;
    $instance = bless {}, $class unless defined $instance;

    return $instance;
}

sub onfido {
    my ($self) = @_;

    return $self->{onfido} //= do {
        $self->add_child(my $service = WebService::Async::Onfido->new(token => BOM::Config::third_party()->{onfido}->{authorization_token}));
        $service;
        }
}

=head2 service_token

Returns the generated WebService token of passed C<service> for the client.

=over 4

=item * C<client> - The client to generate a service token for

=item * C<service> - Name of the service to use for generating the token

=item * C<referrer> - URL of the web page where the Web SDK will be used (required when C<service> is C<onfido>)

=back

=cut

sub service_token {
    my ($client, $args) = @_;

    if ($args->{service} eq 'onfido') {
        return BOM::RPC::v3::Services::Onfido::onfido_service_token($client, $args->{referrer});
    }
}

1;
