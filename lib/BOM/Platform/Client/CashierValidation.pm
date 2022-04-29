package BOM::Platform::Client::CashierValidation;

=head1 NAME

BOM::Platform::Client::CashierValidation

=head1 DESCRIPTION

Handles validation for cashier

=cut

use strict;
use warnings;
no indirect;

use Date::Utility;
use Scalar::Util qw(looks_like_number);
use ExchangeRates::CurrencyConverter qw/convert_currency/;
use Format::Util::Numbers qw/get_min_unit financialrounding/;
use List::Util qw(any);
use Syntax::Keyword::Try;

use BOM::User::Client;
use LandingCompany::Registry;

use BOM::Config::Runtime;
use BOM::Platform::Context qw/request localize/;
use BOM::Config::CurrencyConfig;
use BOM::Platform::Utility qw(error_map);

# custom error codes to override the default error code CashierForwardError
use constant OVERRIDE_ERROR_CODES => qw(
    SelfExclusion
    ASK_CURRENCY
    ASK_AUTHENTICATE
    ASK_FINANCIAL_RISK_APPROVAL
    ASK_TIN_INFORMATION
    ASK_UK_FUNDS_PROTECTION
    ASK_SELF_EXCLUSION_MAX_TURNOVER_SET
    ASK_FIX_DETAILS
    FinancialAssessmentRequired
);

# a mapping from error codes to the FE status codes.
my %error_to_status_mapping = (
    NoResidence                 => 'no_residence',
    SetExistingAccountCurrency  => 'ASK_CURRENCY',
    CashierLocked               => 'cashier_locked_status',
    DisabledAccount             => 'disabled_status',
    CurrencyNotApplicable       => 'illegal_currency',
    DocumentsExpired            => 'documents_expired',
    NotAuthenticated            => 'ASK_AUTHENTICATE',
    FinancialRiskNotApproved    => 'ASK_FINANCIAL_RISK_APPROVAL',
    NoTaxInformation            => 'ASK_TIN_INFORMATION',
    NoUkgcFundsProtection       => 'ASK_UK_FUNDS_PROTECTION',
    NoMaxTuroverLimit           => 'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET',
    UnwelcomeStatus             => 'unwelcome_status',
    CashierRequirementsMissing  => 'ASK_FIX_DETAILS',
    NoWithdrawalOrTradingStatus => 'no_withdrawal_or_trading_status',
    WithdrawalLockedStatus      => 'withdrawal_locked_status',
    HighRiskNotAuthenticated    => 'ASK_AUTHENTICATE',
    PotentialFraud              => 'ASK_AUTHENTICATE',
    system_maintenance_crypto   => 'system_maintenance',
);

=head2 validate

Validates various checks related to cashier including
regulation and compliance requirements.

=over 4

=item * C<$loginid> - For creating an instance of L<BOM::User::Client>.

=item * C<action> - takes either deposit or withdraw to include their specific rules.

=item * C<is_internal> - true when this is an internal transfer.

=item * C<rule_engine> - a rule engine object (please note that we are not allowed to create rule engine objects in this repo)

=back

Returns undef for successful validation or a hashref containing error details.

=cut

sub validate {
    my %args = @_;
    my ($loginid, $action, $is_internal, $underlying_action) = @args{qw(loginid action is_internal underlying_action)};

    my $client = BOM::User::Client->get_client_instance($loginid, 'replica') or return _create_error(localize('Invalid account.'));
    $action =~ s/^withdraw$/withdrawal/;

    my $rule_engine = delete $args{rule_engine};

    $underlying_action //= {};
    $underlying_action = {name => $underlying_action} unless ref $underlying_action;

    my $errors   = check_availability($client, $action) // {};
    my $currency = $client->account ? $client->account->currency_code : '';

    my $failed_rules;

    my $rules_result = $rule_engine->verify_action(
        'cashier_validation',
        underlying_action => $underlying_action->{name} // ('cashier_' . $action),
        $underlying_action->{args}->%*,
        loginid     => $loginid,
        action      => $action,
        currency    => $currency,
        is_internal => $is_internal ? 1 : 0,
        # Keep the rule engine from stopping on failure
        rule_engine_context => {stop_on_failure => 0});
    $failed_rules = $rules_result->failed_rules;

    _convert_rule_failure_to_cashier_error($failed_rules // [], $errors);

    return $errors if $errors->{error};

    return undef;
}

=head2 check_availability

Checks cashier availability. It verifies different global app settings that may suspend payments, cashier or currencies.
There is no business rule checked here.
It takes followng arguments:

=over 4

=item * C<$client> - An object of the type L<BOM::User::Client>.

=item * C<action> - it can be either B<deposit> or B<withdrawal>.

=back

Returns undef for successful validation or a hashref containing error details.

=cut

sub check_availability {
    my ($client, $action) = @_;

    $action =~ s/^withdraw$/withdrawal/;

    my $errors = {};
    _add_error_by_code($errors, 'system_maintenance')
        if (BOM::Config::CurrencyConfig::is_payment_suspended());

    _add_error_by_code($errors, 'system_maintenance')
        if (BOM::Config::CurrencyConfig::is_payment_suspended());

    _add_error_by_code($errors, 'virtual_account')
        if $client->is_virtual;

    return $errors if $errors->{error};

    my $currency      = $client->account ? $client->account->currency_code : '';
    my $currency_type = LandingCompany::Registry::get_currency_type($currency);

    _add_error_by_code($errors, 'system_maintenance')
        if $currency_type eq 'fiat' and BOM::Config::CurrencyConfig::is_cashier_suspended();

    _add_error_by_code($errors, 'system_maintenance_crypto')
        if $currency_type eq 'crypto'
        and (BOM::Config::CurrencyConfig::is_crypto_cashier_suspended() or BOM::Config::CurrencyConfig::is_crypto_currency_suspended($currency));

    _add_error($errors, localize('Deposits are temporarily unavailable for [_1]. Please try later.', $currency), 'system_maintenance')
        if $currency_type eq 'crypto' && BOM::Config::CurrencyConfig::is_crypto_currency_deposit_suspended($currency);

    _add_error($errors, localize('Withdrawals are temporarily unavailable for [_1]. Please try later.', $currency), 'system_maintenance')
        if $currency_type eq 'crypto' && $action eq 'withdrawal' && BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_suspended($currency);

    return $errors;
}

=head2 invalid_currency_error

Generate standard error parameters if currency is invalid.

=over 4

=item * C<currency> - The currency code to check the validity of. B<case-sensitive>

=back

Returns a hashref containing error parameters if currency is invalid, otherwise C<undef>.

=cut

sub invalid_currency_error {
    my ($currency) = @_;

    return undef if BOM::Config::CurrencyConfig::is_valid_currency($currency);

    return {
        code              => 'InvalidCurrency',
        message_to_client => BOM::Platform::Context::localize('The provided currency [_1] is invalid.', $currency),
    };
}

=head2 calculate_to_amount_with_fees

Calculates transfer amount and fees

Args

=over 4

=item * The amount is be transferred (in the currency of the sending account)

=item * The currency of the sending account

=item * The currency of the receiving account

=item * A L<BOM::User::Client> instance of the sending client
Optional: only required to ascertain if client qualifies for PA fee exemption

=item * A L<BOM::User::Client> instance of the receiving client
Optional: only required to ascertain if client qualifies for PA fee exemption

=back

Returns

=over 4

=item * The amount that will be received (in the currency of the receiving account)

=item * The fee charged to the sender (in the currency of the sending account). It is maximum of minimum fee and calculated fee.

=item * The fee percentage applied for transfers between these currencies

B<Note>: If a minimum fee was enforced then this will not reflect the actual fee charged.

=item * Minimum fee amount allowed for the sending account's currency (minimum currency unit).

=item * The fee amount calculated by the fee percent alone (before comparing to the minimum fee).

=back

=cut

sub calculate_to_amount_with_fees {
    my ($amount, $from_currency, $to_currency, $fm_client, $to_client) = @_;
    my $rate_expiry = BOM::Config::CurrencyConfig::rate_expiry($from_currency, $to_currency);

    return ($amount, 0, 0, 0, 0) if $from_currency eq $to_currency;

    # Fee exemption for transfers between an authorised payment agent account and another account under that user.
    return (convert_currency($amount, $from_currency, $to_currency, $rate_expiry), 0, 0, 0, 0)
        if (defined $fm_client
        && defined $to_client
        && $fm_client->is_same_user_as($to_client)
        && ($fm_client->is_pa_and_authenticated() || $to_client->is_pa_and_authenticated()));

    my $currency_config = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();
    my $fee_percent     = $currency_config->{$from_currency}->{$to_currency};

    die "No transfer fee found for $from_currency-$to_currency" unless defined $fee_percent;

    my $fee_calculated_by_percent = $amount * $fee_percent / 100;

    my $min_fee = get_min_unit($from_currency);
    my $fee_applied;

    if ($fee_percent == 0) {
        $fee_applied = 0;
    } elsif ($fee_calculated_by_percent < $min_fee) {
        $fee_applied = $min_fee;
    } else {
        $fee_applied = $fee_calculated_by_percent;
    }

    $amount = convert_currency(($amount - $fee_applied), $from_currency, $to_currency, $rate_expiry);

    die "The amount ($amount) is below the minimum allowed amount (" . get_min_unit($to_currency) . ") for $to_currency."
        if $amount < get_min_unit($to_currency);

    return ($amount, $fee_applied, $fee_percent, $min_fee, $fee_calculated_by_percent);
}

=head2 _create_error

Create error structure.

=over 4

=item * C<message> - localized error message to be returned by api.

=item * C<code> - error code to be returned by api, optional.

=item * C<details> - hashref of additional details to be returned by api, optional.

=back

Returns error structure.

=cut

sub _create_error {
    my ($message, $code, $details) = @_;

    $code = 'CashierForwardError' unless any { $code and $code eq $_ } OVERRIDE_ERROR_CODES;

    return {
        error => {
            code              => $code,
            message_to_client => $message,
            $details ? (details => $details) : (),
        }};
}

=head2 _add_error

Generates first message and accumulates all error codes that FE is interested in.

=over 4

=item * C<current> - hashref to be updated in-place.

=item * C<message> - localized error message to be returned by api.

=item * C<code> - error code to be returned by api, optional.

=item * C<details> - hashref of additional details to be returned by api, optional.

=back

Returns nothing.

=cut

sub _add_error {
    my ($current, $message, $code, $details) = @_;

    $current->{error} //= _create_error($message, $code, $details)->{error};
    push $current->{status}->@*, $code if $code;

    $current->{missing_fields} = $details->{fields} if $code && ($code eq 'ASK_FIX_DETAILS');
}

=head2 _add_error_by_code

Takes the first error message and accumulated FE codes, just like B<_add_error>; but it takes error codes 
and generates localized error messages.

=over 4

=item * C<current> - hashref to be updated in-place.

=item * C<code> - error code to be returned by api, optional.

=item * C<args> - hashref of additional error info, like B<details> and message localization B<params>.

=back

Returns nothing.

=cut

sub _add_error_by_code {
    my ($current, $code, %args) = @_;

    my $message = localize(error_map->{$code}, ref $args{params} eq 'ARRAY' ? $args{params}->@* : $args{params});
    my $details = $args{details};

    $code = $error_to_status_mapping{$code} // $code;

    # some errors were generated without an error code; let's keep it the same as of now.
    $code = undef if $code =~ qr/virtual_account|illegal_currency/;

    _add_error($current, $message, $code, $details);
}

=head2 _convert_rule_failure_to_cashier_error

Processes the list of failures returned by rule-engine and 
adds combines them into the pre-existing error using B<_add_error_by_code>.
It takes the following args:

=over 4

=item * C<rule_failures> - Arrayref of faulures 

=item * C<errors> - previous cashier validation errors combined into a single hash-ref.

=back

Returns nothing.

=cut

sub _convert_rule_failure_to_cashier_error {
    my ($rule_failures, $errors) = @_;

    return 1 unless scalar @$rule_failures;

    # if the first rule has failed with exception, there's something basically wrong.
    die $rule_failures->[0] unless ref $rule_failures->[0];

    for my $failure (@$rule_failures) {
        last unless ref $failure;

        _add_error_by_code($errors, $failure->{error_code}, %$failure);
    }

    return 1;
}

1;
