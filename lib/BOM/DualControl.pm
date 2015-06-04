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
use File::ReadBackwards;

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

sub payment_control_code {
    my $self     = shift;
    my $loginid  = shift;
    my $currency = shift;
    my $amount   = shift;

    return BOM::Utility::Crypt->new(keyname => 'password_counter')
        ->encrypt_payload(
        data => time . '_##_' . $self->staff . '_##_' . $self->transactiontype . '_##_' . $loginid . '_##_' . $currency . '_##_' . $amount);
}

sub batch_payment_control_code {
    my $self     = shift;
    my $filename = shift;

    return BOM::Utility::Crypt->new(keyname => 'password_counter')
        ->encrypt_payload(data => time . '_##_' . $self->staff . '_##_' . $self->transactiontype . '_##_' . $filename);
}

sub validate_client_control_code {
    my $self   = shift;
    my $incode = shift;
    my $email  = shift;

    my $code = BOM::Utility::Crypt->new(keyname => 'password_counter')->decrypt_payload(value => $incode);

    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_client_code_is_valid($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_expiry($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_client_email($code, $email);
    return $error_status if $error_status;
    $error_status = $self->_validate_client_code_already_used($incode);
    return $error_status if $error_status;
    return;
}

sub validate_payment_control_code {
    my $self     = shift;
    my $incode   = shift;
    my $loginid  = shift;
    my $currency = shift;
    my $amount   = shift;

    my $code = BOM::Utility::Crypt->new(keyname => 'password_counter')->decrypt_payload(value => $incode);

    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_code_is_valid($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_expiry($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_loginid($code, $loginid);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_currency($code, $currency);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_amount($code, $amount);
    return $error_status if $error_status;
    $error_status = $self->_validate_staff_payment_limit($amount);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_code_already_used($incode);
    return $error_status if $error_status;

    return;
}

sub validate_batch_payment_control_code {
    my $self     = shift;
    my $incode   = shift;
    my $filename = shift;

    my $code = BOM::Utility::Crypt->new(keyname => 'password_counter')->decrypt_payload(value => $incode);

    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_batch_payment_code_is_valid($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_expiry($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_filename($code, $filename);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_code_already_used($incode);
    return $error_status if $error_status;

    return;
}

sub _validate_empty_code {
    my $self = shift;
    my $code = shift;

    if (not $code) {
        return Error::Base->cuss(
            -type => 'CodeNotProvided',
            -mesg => 'Dual control code is not specified or is invalid',
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
            -mesg => 'Dual control code is not valid',
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
            -type => 'InvalidPaymentCode',
            -mesg => 'Dual control code is not valid',
        );
    }
    return;
}

sub _validate_batch_payment_code_is_valid {
    my $self = shift;
    my $code = shift;

    my @arry = split("_##_", $code);
    if (scalar @arry != 4) {
        return Error::Base->cuss(
            -type => 'InvalidBatchPaymentCode',
            -mesg => 'Dual control code is not valid',
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

sub _validate_payment_code_already_used {
    my $self = shift;
    my $code = shift;

    my $count    = 0;
    my $log_file = File::ReadBackwards->new("/var/log/fixedodds/fmanagerconfodeposit.log");
    while ((defined(my $l = $log_file->readline)) and ($count++ < 200)) {
        my @matches = $l =~ /DCcode=([^\s]+)/g;
        if (grep { $code eq $_ } @matches) {
            return Error::Base->cuss(
                -type => 'CodeAlreadyUsed',
                -mesg => 'This control code has already been used today',
            );
        }
    }
    return;
}

sub _validate_client_code_already_used {
    my $self = shift;
    my $code = shift;

    my $count    = 0;
    my $log_file = File::ReadBackwards->new("/var/log/fixedodds/fclientdetailsupdate.log");
    while ((defined(my $l = $log_file->readline)) and ($count++ < 200)) {
        my @matches = $l =~ /DCcode=([^\s]+)/g;
        if (grep { $code eq $_ } @matches) {
            return Error::Base->cuss(
                -type => 'CodeAlreadyUsed',
                -mesg => 'This control code has already been used today',
            );
        }
    }
    return;
}

sub _validate_client_email {
    my $self  = shift;
    my $code  = shift;
    my $email = shift;

    my @arry = split("_##_", $code);
    if (not $email or $email ne $arry[3]) {
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

sub _validate_filename {
    my $self     = shift;
    my $code     = shift;
    my $filename = shift;

    my @arry = split("_##_", $code);
    if ($filename ne $arry[3]) {
        return Error::Base->cuss(
            -type => 'DifferentFilename',
            -mesg => 'Filename provided does not match with the filename provided during code generation',
        );
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
