package BOM::User::TOTP;

use strict;
use warnings;

use Bytes::Random::Secure;
use Authen::OATH;

=head1 NAME

BOM::User::TOTP - Time-Based One Time Password (TOTP) which uses a secret key and current time.

=head1 SYNOPSIS

 my $secret_key  = BOM::User::TOTP->generate_key();
 my $is_verified = BOM::User::TOTP->verify_totp('secret_key', 'totp');

=cut

=head1 METHODS

=head2 generate_key

Generates a random secret of length 16 and returns it.

=cut

sub generate_key {
    my $key = Bytes::Random::Secure->new(
        Bits        => 160,
        NonBlocking => 1,
    )->string_from(join('', 'a' .. 'z', 'A' .. 'Z', '0' .. '9'), 16);

    return $key;
}

=head2 verify_totp

Verifies if the provided TOTP is correct in accordance with secret key provided. Returns 1 or 0.

=cut

sub verify_totp {
    my ($self, $secret_key, $totp) = @_;
    return 0 unless ($secret_key && $totp);
    my $oath_totp = Authen::OATH->new()->totp($secret_key);
    return int($oath_totp eq $totp);
}

1;
