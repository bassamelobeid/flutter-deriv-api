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
use Cache::RedisDB;
use Crypt::NamedKeys;
use Scalar::Util qw(looks_like_number);

use BOM::Platform::Runtime;
use BOM::Platform::Config;
use JSON::MaybeXS;

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

has _environment => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build__environment {
    my $env = BOM::Platform::Config::on_production() ? 'production' : 'others';
    return $env;
}

sub client_control_code {
    my $self  = shift;
    my $email = shift;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => time . '_##_' . $self->staff . '_##_' . $self->transactiontype . '_##_' . $email . '_##_' . $self->_environment);

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

sub payment_control_code {
    my $self     = shift;
    my $loginid  = shift;
    my $currency = shift;
    my $amount   = shift;

    my $code =
        Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => time . '_##_'
            . $self->staff . '_##_'
            . $self->transactiontype . '_##_'
            . $loginid . '_##_'
            . $currency . '_##_'
            . $amount . '_##_'
            . $self->_environment);

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

sub batch_payment_control_code {
    my $self  = shift;
    my $lines = shift;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => time . '_##_' . $self->staff . '_##_' . $self->transactiontype . '_##_' . $lines . '_##_' . $self->_environment);

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

sub validate_client_control_code {
    my $self   = shift;
    my $incode = shift;
    my $email  = shift;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);

    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_client_code_is_valid($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_expiry($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
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

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);

    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_code_is_valid($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_expiry($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
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
    my $self   = shift;
    my $incode = shift;
    my $lines  = shift;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);

    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_batch_payment_code_is_valid($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_expiry($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_filelinescount($code, $lines);
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
    if (scalar @arry != 5) {
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
    if (scalar @arry != 7) {
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
    if (scalar @arry != 5) {
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

    if (Cache::RedisDB->get('DUAL_CONTROL_CODE', $code)) {
        Cache::RedisDB->del('DUAL_CONTROL_CODE', $code);
    } else {
        return Error::Base->cuss(
            -type => 'CodeAlreadyUsed',
            -mesg => 'This control code has already been used or already expired',
        );
    }
    return;
}

sub _validate_client_code_already_used {
    my $self = shift;
    my $code = shift;

    if (Cache::RedisDB->get('DUAL_CONTROL_CODE', $code)) {
        Cache::RedisDB->del('DUAL_CONTROL_CODE', $code);
    } else {
        return Error::Base->cuss(
            -type => 'CodeAlreadyUsed',
            -mesg => 'This control code has already been used or already expired',
        );
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

    my $payment_limits = JSON::MaybeXS->new->decode(BOM::Platform::Runtime->instance->app_config->payments->payment_limits);
    if ($payment_limits->{$self->staff} and looks_like_number($payment_limits->{$self->staff})) {
        if ($amount > $payment_limits->{$self->staff}) {
            return Error::Base->cuss(
                -type => 'AmountGreaterThanLimit',
                -mesg => 'The amount is larger than authorization limit for staff',
            );
        }
    } else {
        return Error::Base->cuss(
            -type => 'NoPaymentLimitForUser',
            -mesg => 'There is no payment limit configured in the backoffice payment_limits for this user',
        );
    }
    return;
}

sub _validate_filelinescount {
    my $self  = shift;
    my $code  = shift;
    my $lines = shift;

    my @arry = split("_##_", $code);
    if ($lines ne $arry[3]) {
        return Error::Base->cuss(
            -type => 'DifferentFile',
            -mesg => 'File provided does not match with the file provided during code generation',
        );
    }
    return;
}

sub _validate_environment {
    my $self = shift;
    my $code = shift;

    my @arry = split("_##_", $code);
    if ($self->_environment ne $arry[-1]) {
        return Error::Base->cuss(
            -type => 'DifferentEnvironment',
            -mesg => 'Code provided has different environment. Please use the code generated on same environment.',
        );
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
