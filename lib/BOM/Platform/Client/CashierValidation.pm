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

use BOM::User::Client;
use LandingCompany::Registry;

use BOM::Config::Runtime;
use BOM::Platform::Context qw/request localize/;
use BOM::Config::CurrencyConfig;

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
);

=head2 validate

Validates various checks related to cashier including
regulation, compliance requirements

=over 4

=item * C<$loginid> - For creating an instance of L<BOM::User::Client>.

=item * C<action> - takes either deposit or withdraw to include their specific rules.

=item * C<is_internal> - true when this is an internal transfer.

=back

Returns undef for successful validation or a hashref containing error details.

=cut

sub validate {
    my ($loginid, $action, $is_internal) = @_;

    my $client = BOM::User::Client->get_client_instance($loginid, 'replica') or return _create_error(localize('Invalid account.'));

    my @validations = (\&base_validation);
    push @validations, \&deposit_validation  if $action eq 'deposit';
    push @validations, \&withdraw_validation if $action eq 'withdraw';

    for my $sub (@validations) {
        my $res = $sub->($client, $is_internal);
        return $res if $res->{error};
    }

    return undef;
}

=head2 base_validation

Check general rules that determines the cashier is locked completely or not.

=over 4

=item * C<client> - an instance of L<BOM::User::Client>.

=back

Returns empty hashref for successful validation or a hashref containing error details.

=cut

sub base_validation {
    my ($client, $is_internal) = @_;

    my $errors = {};

    _add_error($errors, localize('Sorry, cashier is temporarily unavailable due to system maintenance.'), 'system_maintenance')
        if (BOM::Config::CurrencyConfig::is_payment_suspended());

    _add_error($errors, localize('This is a virtual-money account. Please switch to a real-money account to access cashier.'))
        if $client->is_virtual;

    my $currency = $client->default_account ? $client->default_account->currency_code : '';
    _add_error($errors, localize('Please set the currency.'), 'ASK_CURRENCY') unless $currency;

    my $currency_type = LandingCompany::Registry::get_currency_type($currency);

    _add_error($errors, localize('Sorry, cashier is temporarily unavailable due to system maintenance.'), 'system_maintenance')
        if $currency_type eq 'fiat' and BOM::Config::CurrencyConfig::is_cashier_suspended();

    _add_error($errors, localize('Sorry, crypto cashier is temporarily unavailable due to system maintenance.'), 'system_maintenance')
        if $currency_type eq 'crypto'
        and (BOM::Config::CurrencyConfig::is_crypto_cashier_suspended() or BOM::Config::CurrencyConfig::is_crypto_currency_suspended($currency));

    _add_error($errors, localize('Please set your country of residence.'), 'no_residence') unless $client->residence;

    # better to do generic error validation before landing company or account specific
    _add_error($errors, localize('Your cashier is locked.'),   'cashier_locked_status') if $client->status->cashier_locked;
    _add_error($errors, localize('Your account is disabled.'), 'disabled_status')       if $client->status->disabled;

    my $landing_company = $client->landing_company;
    _add_error($errors, localize('[_1] transactions may not be performed with this account.', $currency))
        unless $landing_company->is_currency_legal($currency);

    _add_error($errors, localize('Please complete the financial assessment form to lift your withdrawal and trading limits.'),
        'FinancialAssessmentRequired')
        unless $client->is_financial_assessment_complete or $is_internal;

    _add_error($errors,
        localize('Your identity documents have expired. Visit your account profile to submit your valid documents and unlock your cashier.'),
        'documents_expired')
        if $client->documents->expired;

    # landing company or country specific validations
    if ($landing_company->short eq 'maltainvest') {
        _add_error($errors, localize('Please authenticate your account.'), 'ASK_AUTHENTICATE') unless $client->fully_authenticated;

        _add_error($errors, localize('Financial Risk approval is required.'), 'ASK_FINANCIAL_RISK_APPROVAL')
            unless $client->status->financial_risk_approval;

        _add_error($errors,
            localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.'),
            'ASK_TIN_INFORMATION')
            unless $client->status->crs_tin_information;
    }

    my $config = request()->brand->countries_instance->countries_list->{$client->residence};

    if ($client->landing_company->short ne 'maltainvest'
        && ($config->{need_set_max_turnover_limit} || $client->landing_company->check_max_turnover_limit_is_set))
    {
        # MX only
        _add_error($errors, localize('Please accept Funds Protection.'), 'ASK_UK_FUNDS_PROTECTION')
            if $config->{ukgc_funds_protection} && !$client->status->ukgc_funds_protection;

        _add_error(
            $errors,
            localize('Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.'),
            'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET'
        ) if $client->status->max_turnover_limit_not_set;
    }

    return $errors;
}

=head2 deposit_validation

Check deposit specific rules that determines the deposit is locked or not.

=over 4

=item * C<client> - an instance of L<BOM::User::Client>.

=back

Returns empty hashref for successful validation or a hashref containing error details.

=cut

sub deposit_validation {
    my ($client) = @_;

    my $errors = {};

    my $lim = $client->get_self_exclusion_until_date;
    _add_error(
        $errors,
        localize(
            'Sorry, but you have self-excluded yourself from the website until [_1]. If you are unable to place a trade or deposit after your self-exclusion period, please contact the Customer Support team for assistance.',
            $lim
        ),
        'SelfExclusion'
    ) if $lim;

    _add_error($errors, localize('Your account is restricted to withdrawals only.'), 'unwelcome_status')
        if $client->status->unwelcome;

    if (my @missing_fields = $client->missing_requirements('deposit')) {
        _add_error($errors, localize('Your profile appears to be incomplete. Please update your personal details to continue.'),
            'ASK_FIX_DETAILS', {fields => \@missing_fields});
        $errors->{missing_fields} = \@missing_fields;
    }

    if ($client->default_account) {
        my $currency = $client->default_account->currency_code;
        if (LandingCompany::Registry::get_currency_type($currency) eq 'crypto') {
            _add_error($errors, localize('Deposits are temporarily unavailable for [_1]. Please try later.', $currency), 'system_maintenance')
                if BOM::Config::CurrencyConfig::is_crypto_currency_deposit_suspended($currency);
        }
    }

    return $errors;
}

=head2 withdraw_validation

Check withdrawal specific rules that determines the withdrawal is locked or not.

=over 4

=item * C<client> - an instance of L<BOM::User::Client>.

=back

Returns empty hashref for successful validation or a hashref containing error details.

=cut

sub withdraw_validation {
    my ($client) = @_;

    my $errors = {};

    _add_error($errors, localize('Your account is restricted to deposits only.'), 'no_withdrawal_or_trading_status')
        if $client->status->no_withdrawal_or_trading;

    _add_error($errors, localize('Your account is locked for withdrawals.'), 'withdrawal_locked_status')
        if $client->status->withdrawal_locked;

    _add_error($errors, localize('Please authenticate your account.'), 'ASK_AUTHENTICATE')
        if $client->risk_level eq 'high' and not $client->fully_authenticated;

    if (my @missing_fields = $client->missing_requirements('withdrawal')) {
        _add_error($errors, localize('Your profile appears to be incomplete. Please update your personal details to continue.'),
            'ASK_FIX_DETAILS', {fields => \@missing_fields});
        $errors->{missing_fields} = \@missing_fields;
    }

    if ($client->default_account) {
        my $currency = $client->default_account->currency_code;
        if (LandingCompany::Registry::get_currency_type($currency) eq 'crypto') {
            _add_error($errors, localize('Withdrawals are temporarily unavailable for [_1]. Please try later.', $currency), 'system_maintenance')
                if BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_suspended($currency);
        }
    }

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

    $current->{error} = _create_error($message, $code, $details)->{error} unless $current->{error};
    push $current->{status}->@*, $code if $code;
}

1;
