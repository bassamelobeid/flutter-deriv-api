package BOM::Platform::EmailToken;

=head1 NAME

BOM::Platform::EmailToken

=head1 DESCRIPTION

This class provides common functionality to validate token for emails

=head1 METHODS

=head2 $class->new(email => $email)

Create new object with the given attributes' values

=cut

use 5.010;
use Moose;
use Crypt::CBC;
use BOM::Utility::Log4perl qw(get_logger);
use URL::Encode qw( url_encode url_decode );
use BOM::System::Config;

sub _cipher {
    state $crypt = Crypt::CBC->new({
        key    => BOM::System::Config::aes_keys->{email_verification_token}->{1},
        cipher => "Blowfish"
    });
    return $crypt;
}

sub get_token {
    my $email = shift;

    my $hcstring = lc $email . '_##_' . time;
    return url_encode(_cipher()->encrypt($hcstring));
}

sub validate_token {
    my $token = shift;
    my $email = shift;
    my @arry;
    if ($token and $email) {
        @arry = split("_##_", _cipher()->decrypt(url_decode($token)));
        if (scalar @arry > 1 and lc $email eq $arry[0]) {
            if (time - $arry[1] < 3600) {    # check if token time is less than 1 hour of current time
                return 1;
            }
        }
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
