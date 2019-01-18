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
use Date::Utility;
use Error::Base;
use Cache::RedisDB;
use Crypt::NamedKeys;

use ExchangeRates::CurrencyConverter qw(in_usd);

use BOM::Config;
use BOM::Backoffice::Script::ValidateStaffPaymentLimit;

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
    my $env = BOM::Config::on_production() ? 'production' : 'others';
    return $env;
}

sub client_control_code {
    my ($self, $email, $user_id) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, $email, $user_id, $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

sub payment_control_code {
    my ($self, $loginid, $currency, $amount) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, $loginid, $currency, $amount, $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

sub batch_payment_control_code {
    my ($self, $lines) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, $lines, $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

sub client_anonymization_control_code {
    my ($self, $loginid) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, $loginid, $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

sub validate_client_control_code {
    my ($self, $incode, $email, $user_id) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);
    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_element_count($code, 6);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_client_email($code, $email);
    return $error_status if $error_status;
    $error_status = $self->_validate_client_userid($code, $user_id);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;
    return;
}

sub validate_payment_control_code {
    my ($self, $incode, $loginid, $currency, $amount) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);

    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_element_count($code, 7);
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
    $error_status = BOM::Backoffice::Script::ValidateStaffPaymentLimit::validate($self->staff, in_usd($amount, $currency));
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;

    return;
}

sub validate_batch_payment_control_code {
    my ($self, $incode, $lines) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);

    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_element_count($code, 5);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_filelinescount($code, $lines);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;

    return;
}

sub validate_client_anonymization_control_code {
    my ($self, $incode, $loginid) = @_;
    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);
    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_element_count($code, 5);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_loginid($code, $loginid);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;
    return;
}

sub _validate_empty_code {
    my ($self, $code) = @_;

    if (not $code) {
        return Error::Base->cuss(
            -type => 'CodeNotProvided',
            -mesg => 'Dual control code is not specified or is invalid',
        );
    }
    return;
}

sub _validate_code_element_count {
    my ($self, $code, $element_count) = @_;

    my @arry = split("_##_", $code);
    if (@arry != $element_count) {
        return Error::Base->cuss(
            -type => 'InvalidClientCode',
            -mesg => 'Dual control code has unexpected number of elements',
        );
    }
    return;
}

sub _validate_fellow_staff {
    my ($self, $code) = @_;

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
    my ($self, $code) = @_;

    my @arry = split("_##_", $code);
    if ($self->transactiontype ne $arry[2]) {
        return Error::Base->cuss(
            -type => 'InvalidTransactionType',
            -mesg => 'Transaction type does not match with type provided during code generation',
        );
    }
    return;
}

sub _validate_code_already_used {
    my ($self, $code) = @_;

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
    my ($self, $code, $email) = @_;

    my @arry = split("_##_", $code);
    if (not $email or $email ne $arry[3]) {
        return Error::Base->cuss(
            -type => 'DifferentEmail',
            -mesg => 'Email provided does not match with the email provided during code generation',
        );
    }
    return;
}

sub _validate_client_userid {
    my ($self, $code, $user_id) = @_;

    my @arry = split("_##_", $code);
    if (not $user_id or not $arry[4] or $user_id ne $arry[4]) {
        return Error::Base->cuss(
            -type => 'DifferentUserId',
            -mesg => 'UserId provided does not match with the UserId provided during code generation',
        );
    }
    return;
}

sub _validate_payment_loginid {
    my ($self, $code, $loginid) = @_;

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
    my ($self, $code, $currency) = @_;

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
    my ($self, $code, $amount) = @_;

    my @arry = split("_##_", $code);
    if ($amount ne $arry[5]) {
        return Error::Base->cuss(
            -type => 'DifferentAmount',
            -mesg => 'Amount provided does not match with the amount provided during code generation',
        );
    }
    return;
}

sub _validate_filelinescount {
    my ($self, $code, $lines) = @_;

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
    my ($self, $code) = @_;

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
