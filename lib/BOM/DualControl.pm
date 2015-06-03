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
use Error::Base;

use BOM::Utility::Crypt;
use BOM::Platform::Runtime;

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

sub client_payment_control_code {
    my $self     = shift;
    my $loginid  = shift;
    my $currency = shift;
    my $amount   = shift;

    return BOM::Utility::Crypt->new(keyname => 'password_counter')
        ->encrypt_payload(
        data => time . '_##_' . $self->staff . '_##_' . $self->transactiontype . '_##_' . $loginid . '_##_' . $currency . '_##_' . $amount);
}

sub validate_client_control_code {
    my $self  = shift;
    my $code  = shift;
    my $type  = shift;
    my $email = shift;

    $code = BOM::Utility::Crypt->new(keyname => 'password_counter')->decrypt_payload(value => $code);

    my $error_status = $self->_validate_empty_code($code);
    $error_status = $self->_validate_client_code_is_valid($code);
    $error_status = $self->_validate_code_expiry($code);
    $error_status = $self->_validate_fellow_staff($code);
    $error_status = $self->_validate_transaction_type($code);
    $error_status = $self->_validate_client_email($code, $email);
    if ($error_status) {
        return $error_status;
    }
    return;
}

sub validate_payment_control_code {
    my $self     = shift;
    my $code     = shift;
    my $type     = shift;
    my $loginid  = shift;
    my $currency = shift;
    my $amount   = shift;

    $code = BOM::Utility::Crypt->new(keyname => 'password_counter')->decrypt_payload(value => $code);

    my $error_status = $self->_validate_empty_code($code);
    $error_status = $self->_validate_payment_code_is_valid($code);
    $error_status = $self->_validate_code_expiry($code);
    $error_status = $self->_validate_fellow_staff($code);
    $error_status = $self->_validate_transaction_type($code);
    $error_status = $self->_validate_payment_loginid($code, $loginid);
    $error_status = $self->_validate_payment_currency($code, $currency);
    $error_status = $self->_validate_payment_amount($code, $amount);
    $error_status = $self->_validate_staff_payment_limit($code, $amount);
    return $error_status if $error_status;

    return;
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

    my @arry = split("_##_", $code);
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

    my @arry = split("_##_", $code);
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

    my @arry = split("_##_", $code);
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

    my @arry = split("_##_", $code);
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

    my @arry = split("_##_", $code);
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

    my @arry = split("_##_", $code);
    if ($email ne $arry[3]) {
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

    my @arry = split("_##_", $code);
    if ($loginid ne $arry[3]) {
        return Error::Base->cuss(
            -type => 'DifferentLoginid',
            -mesg => 'Loginid provided does not match with the loginid provided during code generation',
        );
    }
    return;
}

sub _validate_payment_currency {
    my $self     = shift;
    my $code     = shift;
    my $currency = shift;

    my @arry = split("_##_", $code);
    if ($currency ne $arry[4]) {
        return Error::Base->cuss(
            -type => 'DifferentCurrency',
            -mesg => 'Currency provided does not match with the currency provided during code generation',
        );
    }
    return;
}

sub _validate_payment_amount {
    my $self   = shift;
    my $code   = shift;
    my $amount = shift;

    my @arry = split("_##_", $code);
    if ($amount ne $arry[5]) {
        return Error::Base->cuss(
            -type => 'DifferentAmount',
            -mesg => 'Amount provided does not match with the amount provided during code generation',
        );
    }
    return;
}

sub _validate_staff_payment_limit {
    my $self   = shift;
    my $amount = shift;

    my $payment_limits = JSON::from_json(BOM::Platform::Runtime->instance->app_config->payments->payment_limits);
    if (exists $payment_limits->{$self->staff}) {
        if ($amount > $payment_limits->{$self->staff}) {
            return Error::Base->cuss(
                -type => 'AmountGreaterThanLimit',
                -mesg => 'The amount is larger than authorization limit for staff',
            );
        }
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
