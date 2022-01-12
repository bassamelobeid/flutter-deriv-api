package BOM::Platform::Client::IdentityVerification;

=head1 NAME

BOM::Platform::Client::IdentityVerification

=head1 DESCRIPTION

Some sort of IDV tools and utilities that are going to be used in different modules.

=cut

use strict;
use warnings;
no indirect;

use Date::Utility;

my @muted_providers = qw/ zaig /;

=head2 is_mute_provider

Transform IDV providers' response to a fixed and guessable format, also understandable by our rule engine.

=over 4

=item * C<provider> - The IDV provider

=back

returns TRUE/FALSE if the provider is in the list of muted IDV providers

=cut

sub is_mute_provider {
    my ($provider) = @_;

    for my $mute_provider (@muted_providers) {
        return 1 if $mute_provider eq $provider;
    }

    return 0;
}

=head2 transform_response

Transform IDV providers' response to a fixed and guessable format, also understandable by our rule engine.

=over 4

=item * C<provider> - The IDV provider

=item * C<response> - The raw response we get from IDV

=back

returns undef unless the $provider is defined and a subrutine is defined for it

=cut

sub transform_response {
    my ($provider, $response) = @_;

    my $sub = BOM::Platform::Client::IdentityVerification->can('_transform_' . $provider . '_response');
    return $sub->($response) if $sub;
    return undef;
}

=head2 _transform_smile_identity_response

The SmileID API's response transformator.

=over 4

=item * C<response> - The raw response we get from IDV

=back

returns a hash of transformed response for smile identity

=cut

sub _transform_smile_identity_response {
    my ($response) = @_;
    my $expiration_date = undef;
    $expiration_date = eval { Date::Utility->new($response->{ExpirationDate}) } if $response->{ExpirationDate};

    return {
        full_name       => $response->{FullName},
        date_of_birth   => $response->{DOB},
        expiration_date => $expiration_date,
    };
}

1
