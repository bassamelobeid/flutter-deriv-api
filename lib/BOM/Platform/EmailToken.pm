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

has email => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has token => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    builder => '_build_token'
);

sub _build_token {
    my $self     = shift;
    my $hcstring = $self->email . '_##_' . time;
    return url_encode($self->_cipher->encrypt($hcstring));
}

sub validate_token {
    my $self  = shift;
    my $token = shift;

    my @arry = split("_##_", $self->_cipher->decrypt(url_decode($token)));
    if (scalar @arry > 1 and $self->email eq $arry[0]) {
        if (time - $arry[1] < 7200) {    # check if token time is less than 2 hour of current time
            return 1;
        }
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
