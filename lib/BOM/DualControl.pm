package BOM::DualControl;

=head1 NAME

BOM::DualControl

=head1 DESCRIPTION

This class provides common functionality to create and validate dual control codes

=head1 METHODS

=head2 $class->new({staff => $staff, transactiontype => $transtype})

Create new object with the given attributes' values

=cut

use 5.010;
use Moose;
use DateTime;
use BOM::Utility::Crypt;

has staff => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has transactiontype => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

sub client_control_code {
    my $self  = shift;
    my $email = shift;

    return BOM::Utility::Crypt->new(keyname => 'password_counter')
        ->encrypt_payload(data => time . '_##_' . $self->staff . '_##_' . $self->transactiontype . '_##_' . $email);
}

sub client_payment_code {
    my $self     = shift;
    my $loginid  = shift;
    my $currency = shift;
    my $amount   = shift;

    return BOM::Utility::Crypt->new(keyname => 'password_counter')
        ->encrypt_payload(data => time . '_##_' . $self->staff . '_##_' . $self->transactiontype . '_##_' . $loginid . '_##_' . $currency . '_##_' . $amount);
}

sub _validate_empty_code {
    my $self = shift;
    my $code = shift;
    if (not $code) {
        return Error::Base->cuss(
            -type => 'CodeNotProvided',
            -mesg => 'Dual control code is not specified.',
        );
    }
    return;
}

sub _validate_client_code_is_valid {
    my $self = shift;
    my $code = shift;
    my @arry = split("_##_", $self->_cipher->decrypt(url_decode($code)));
    if (scalar @arry != 4) {
        return Error::Base->cuss(
            -type => 'InvalidClientCode',
            -mesg => 'Dula control code is not valid',
        );
    }
    return;
}

sub _validate_payment_code_is_valid {
    my $self = shift;
    my $code = shift;
    my @arry = split("_##_", $self->_cipher->decrypt(url_decode($code)));
    if (scalar @arry != 6) {
        return Error::Base->cuss(
            -type => 'InvalidClientCode',
            -mesg => 'Dula control code is not valid',
        );
    }
    return;
}

sub _validate_code_expiry {
    my $self = shift;
    my $code = shift;
    my @arry = split("_##_", $self->_cipher->decrypt(url_decode($code)));
    if (DateTime->from_epoch(epoch => time)->ymd ne DateTime->from_epoch(epoch => $arry[0])->ymd) {
        return Error::Base->cuss(
            -type => 'CodeExpired',
            -mesg => 'The code provided has expired. Please generate new one.',
        );
    }
    return;
}

sub _validate_fellow_staff {
    my $self = shift;
    my $code = shift;
    my @arry = split("_##_", $self->_cipher->decrypt(url_decode($code)));
    if ($self->staff eq $arry[1]) {
        return Error::Base->cuss(
            -type => 'SameStaff',
            -mesg => 'Fellow staff name for dual control code cannot be yourself',
        );
    }
    return;
}

sub _validate_transaction_type {
    my $self = shift;
    my $code = shift;

    my @arry = split("_##_", $self->_cipher->decrypt(url_decode($code)));
    if ($self->transactiontype ne $arry[2]) {
        return Error::Base->cuss(
            -type => 'InvalidTransactionType',
            -mesg => 'Transaction type does not match with type provided during code generation',
        );
    }
    return;
}

sub _validate_client_email {
    my $self  = shift;
    my $code  = shift;
    my $email = shift;

    my @arry = split("_##_", $self->_cipher->decrypt(url_decode($code)));
    if ($email ne $arry[2]) {
        return Error::Base->cuss(
            -type => 'DifferentEmail',
            -mesg => 'Email provided does not match with the email provided during code generation',
        );
    }
    return;
}

sub _validate_payment_loginid {
    my $self    = shift;
    my $code    = shift;
    my $loginid = shift;
}

sub _validate_payment_currency {
    my $self     = shift;
    my $code     = shift;
    my $currency = shift;
}

sub _validate_payment_amount {
    my $self   = shift;
    my $code   = shift;
    my $amount = shift;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
