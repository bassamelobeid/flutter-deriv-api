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
use Digest::SHA qw(sha256_hex);
use List::Util  qw(any);

use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::User;

use BOM::Config;
use BOM::Backoffice::Script::ValidateStaffPaymentLimit;

use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);

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

=head2 self_tagging_control_code

Generates self-Tagging DCC in left main menu

=cut

sub self_tagging_control_code {
    my ($self) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

=head2 tactical_index_control_code

Generates tactical index DCC used in feed_configuration.cgi

=cut

sub tactical_index_control_code {
    my ($self, $payload) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, $payload, $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

=head2 payment_control_code

Generates payment DCC

=cut

sub payment_control_code {
    my ($self, $loginid, $currency, $amount) = @_;

    die "Invalid Virtual Client LoginID used\n" if $loginid =~ BOM::User::Client->VIRTUAL_REGEX;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, $loginid, $currency, $amount, $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

=head2 batch_payment_control_code

Generates batch payment DCC

=cut

sub batch_payment_control_code {
    my ($self, $lines) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, checksum_for_records($lines), $self->_environment));

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

=head2 payments_settings_code

Generates payments settings DCC

=cut

sub payments_settings_code {
    my ($self) = @_;
    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

=head2 batch_anonymization_control_code

Generates DCC code to batch anonymization

=cut

sub batch_anonymization_control_code {
    my ($self, $lines) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, checksum_for_records($lines), $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

=head2 create_compliance_dashboard_control_code

Generates compliance dashboard DCC

=cut

sub create_compliance_dashboard_control_code {

    my ($self, $data) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, sha256_hex($data), $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;
}

=head2 batch_status_update_control_code

Generates DCC code to batch update client status code

=cut

sub batch_status_update_control_code {
    my ($self, $lines) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, checksum_for_records($lines), $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;

}

=head2 create_impersonate_control_code

Dual control code to impersonate a client . This verification code is used to verify the staffs identity

=cut

sub create_impersonate_control_code {
    my ($self, $loginid) = @_;
    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')
        ->encrypt_payload(data => join('_##_', time, $self->staff, $self->transactiontype, $loginid, $self->_environment));

    Cache::RedisDB->set("DUAL_CONTROL_CODE", $code, $code, 3600);

    return $code;

}

sub validate_client_control_code {
    my ($self, $incode, $email, $user_id) = @_;

    my $code         = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);
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

=head2 validate_impersonate_control_code

Validates the dcc code of impersonate client . This verification code is used to verify the staffs identity and the client id

=cut

sub validate_impersonate_control_code {
    my ($self, $incode, $loginid) = @_;

    my $code         = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);
    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_element_count($code, 5);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_loginid($code, $loginid);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;
}

=head2 validate_self_tagging_control_code

Validates Self-Tagging DCC in left main menu

=cut

sub validate_self_tagging_control_code {
    my ($self, $incode) = @_;

    my $code         = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);
    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_element_count($code, 4);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;
    return;
}

=head2 validate_payment_control_code

Validates payment DCC

=cut

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

=head2 validate_batch_payment_control_code

Validates batch payment DCC

=cut

sub validate_batch_payment_control_code {
    my ($self, $incode, $lines) = @_;

    die 'invalid lines provided' unless ref($lines) eq 'ARRAY';
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
    $error_status = $self->_validate_filelines($code, $lines);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;

    return;
}

=head2 validate_batch_payment_control_code

Validates batch payment DCC

=cut

sub validate_batch_account_transfer_control_code {
    my ($self, $incode, $account_list) = @_;

    die 'invalid account list provided' unless ref($account_list) eq 'ARRAY';
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
    $error_status = $self->_validate_account_list($code, $account_list);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;

    return;
}

=head2 validate_client_anonymization_control_code

Validates Client anonymization DCC

=cut

sub validate_client_anonymization_control_code {
    my ($self, $incode, $loginid) = @_;
    my $code         = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);
    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_element_count($code, 5);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_payment_loginid($code, $loginid);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;
    return undef;
}

=head2 validate_batch_status_update_control_code

Validates batch client status update DCC

=cut

sub validate_batch_status_update_control_code {
    my ($self, $incode, $lines) = @_;

    my $code         = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);
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
    $error_status = $self->_validate_filelines($code, $lines);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;

    return;
}

=head2 validate_batch_anonymization_control_code

Validates batch anonymizatio DCC

=cut

sub validate_batch_anonymization_control_code {
    my ($self, $incode, $lines) = @_;

    my $code         = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);
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
    $error_status = $self->_validate_filelines($code, $lines);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;

    return;
}

=head2 validate_compliance_dashboard_control_code_npj
Validate compliance dashboard dcc

=cut

sub validate_compliance_dashboard_control_code {
    my ($self, $incode, $data) = @_;

    my $code = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);

    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;
    $error_status = $self->_validate_record_data_checksum($code, $data);
    return $error_status if $error_status;

    return;
}

sub validate_payments_settings_control_code {
    my ($self, $incode) = @_;
    my $code         = Crypt::NamedKeys->new(keyname => 'password_counter')->decrypt_payload(value => $incode);
    my $error_status = $self->_validate_empty_code($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_element_count($code, 4);
    return $error_status if $error_status;
    $error_status = $self->_validate_environment($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_fellow_staff($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_transaction_type($code);
    return $error_status if $error_status;
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;
    return undef;
}

=head2 validate_tactical_index_control_code

Validates tactical index DCC

=cut

sub validate_tactical_index_control_code {
    my ($self, $incode, $payload_to_check) = @_;

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
    $error_status = $self->_validate_code_already_used($incode);
    return $error_status if $error_status;

    my @arry    = split("_##_", $code);
    my $payload = $arry[3];

    #compare the two payloads
    #if they are not the same, return error on which field is different
    $payload          = decode_json_utf8($payload);
    $payload_to_check = decode_json_utf8($payload_to_check);

    my $mismatched_key;
    foreach my $key (keys %$payload) {
        if ($payload->{$key} ne $payload_to_check->{$key}) {

            # we wanted a string of mismatched key like a, b, c
            unless ($mismatched_key) {
                $mismatched_key = $key;
            } else {
                $mismatched_key = join(", ", $mismatched_key, $key);
            }
        }
    }

    if ($mismatched_key) {
        return Error::Base->cuss(
            -type => 'Invalid Parameters',
            -mesg =>
                "Current parameters provided does not match with the parameters provided during code generation. Mismatched key: $mismatched_key",
        );
    }
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
    if (uc $loginid ne uc $arry[3]) {
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

=head2 _validate_record_data_checksum

Checks validity of the data being inserted with DCC 
=cut

sub _validate_record_data_checksum {
    my ($self, $code, $data) = @_;

    my @arry = split("_##_", $code);
    if (sha256_hex($data) ne $arry[3]) {
        return Error::Base->cuss(
            -type => 'DifferentData',
            -mesg => 'Data does not match with the data provided at code generation.',
        );
    }
    return;
}

=head2 _validate_filelines

Checks validity of the CSV file

=cut

sub _validate_filelines {
    my ($self, $code, $lines) = @_;

    my @arry = split("_##_", $code);
    if (checksum_for_records($lines) ne $arry[3]) {
        return Error::Base->cuss(
            -type => 'DifferentFile',
            -mesg => 'File provided does not match with the file provided during code generation',
        );
    }
    return;
}

=head2 _validate_account_list

Checks validity of the CSV file

=cut

sub _validate_account_list {
    my ($self, $code, $lines) = @_;

    my @arry = split("_##_", $code);
    if (checksum_for_records($lines) ne $arry[3]) {
        return Error::Base->cuss(
            -type => 'DifferentAccountList',
            -mesg => 'Account list provided does not match with the account list provided during code generation',
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

=head2 checksum_for_records

Calculates SHA checksum for array of strings.

=over 4

=item * C<lines> - ref of array

=back

Returns string with checksum of Array.

=cut

sub checksum_for_records {
    my $lines = shift;

    die 'invalid lines provided' if ref($lines) ne 'ARRAY';

    my $str = join "\0" => $lines->@*;

    return sha256_hex($str);
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
