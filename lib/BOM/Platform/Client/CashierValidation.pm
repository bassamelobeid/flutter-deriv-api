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

=head2 validate

Validates various checks related to cashier including
regulation, compliance requirements

=cut

sub validate {
    my ($loginid, $action) = @_;

    return _create_error(localize('Sorry, cashier is temporarily unavailable due to system maintenance.'))
        if (BOM::Config::CurrencyConfig::is_payment_suspended());

    my $client = BOM::User::Client->new({
            loginid      => $loginid,
            db_operation => 'replica'
        }) or return _create_error(localize('Invalid account.'));

    return _create_error(localize('This is a virtual-money account. Please switch to a real-money account to access cashier.'))
        if $client->is_virtual;

    # Self-excluded clients are not allowed to deposit
    if ($action eq 'deposit') {
        my $lim = $client->get_self_exclusion_until_date;
        return _create_error(
            localize(
                'Sorry, but you have self-excluded yourself from the website until [_1]. If you are unable to place a trade or deposit after your self-exclusion period, please contact the Customer Support team for assistance.',
                $lim
            ),
            'SelfExclusion'
        ) if $lim;
    }

    my $currency = $client->default_account ? $client->default_account->currency_code : '';
    return _create_error(localize('Please set the currency.'), 'ASK_CURRENCY') unless $currency;

    return _create_error(localize('Please set your country of residence.')) unless $client->residence;

    # better to do generic error validation before landing company or account specific
    return _create_error(localize('Your cashier is locked.'))   if ($client->status->cashier_locked);
    return _create_error(localize('Your account is disabled.')) if ($client->status->disabled);

    my $landing_company = $client->landing_company;
    return _create_error(localize('[_1] transactions may not be performed with this account.', $currency))
        unless ($landing_company->is_currency_legal($currency));

    return _create_error(
        localize('Your identity documents have expired. Visit your account profile to submit your valid documents and unlock your cashier.'))
        if ($client->documents_expired);

    # landing company or country specific validations
    if ($landing_company->short eq 'maltainvest') {
        return _create_error(localize('Please authenticate your account.'), 'ASK_AUTHENTICATE') unless $client->fully_authenticated;

        return _create_error(localize('Financial Risk approval is required.'), 'ASK_FINANCIAL_RISK_APPROVAL')
            unless $client->status->financial_risk_approval;

        return _create_error(
            localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.'),
            'ASK_TIN_INFORMATION')
            unless $client->status->crs_tin_information;
    }

    my $config = request()->brand->countries_instance->countries_list->{$client->residence};

    if ($client->landing_company->short ne 'maltainvest'
        && ($config->{need_set_max_turnover_limit} || $client->landing_company->check_max_turnover_limit_is_set))
    {
        return _create_error(localize('Please accept Funds Protection.'), 'ASK_UK_FUNDS_PROTECTION')
            if $config->{ukgc_funds_protection}
            && !$client->status->ukgc_funds_protection;
        return _create_error(localize('Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.'),
            'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET')
            if $client->status->max_turnover_limit_not_set;
    }
    # action specific validation should be last to be validated
    return _create_error(localize('Your account is restricted to withdrawals only.'))
        if ($action eq 'deposit' and $client->status->unwelcome);

    return _create_error(localize('Your account is restricted to deposits only.'))
        if ($action eq 'withdraw' and $client->status->no_withdrawal_or_trading);

    return _create_error(localize('Your account is locked for withdrawals.'))
        if ($action eq 'withdraw' and $client->status->withdrawal_locked);

    my @missing_fields;
    @missing_fields = $client->missing_requirements('deposit')    if $action eq 'deposit';
    @missing_fields = $client->missing_requirements('withdrawal') if $action eq 'withdraw';

    return _create_error(localize('Your profile appears to be incomplete. Please update your personal details to continue.'),
        'ASK_FIX_DETAILS', {fields => \@missing_fields})
        if @missing_fields;

    return;
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

=head2 pre_withdrawal_validation

Validates withdrawal amount

Used to validate withdrawal request before forwarding
to external cashiers

As of now doughflow have these checks in their code
but crypto cashier needs it explicitly

=cut

sub pre_withdrawal_validation {
    my ($loginid, $amount) = @_;

    return _create_error(localize('Invalid amount.')) if (not $amount or not looks_like_number($amount) or $amount <= 0);

    my $client = BOM::User::Client->new({
            loginid      => $loginid,
            db_operation => 'replica'
        }) or return _create_error(localize('Invalid account.'));

    # TODO: implement logic to compare to EUR/USD limits
    # as currenctly it returns amount in account currency
    my $total = 0;
    if (my $p = _withdrawal_validation_period($client->landing_company->short)) {
        $total = BOM::Database::DataMapper::Payment->new({client_loginid => $client->loginid})->get_total_withdrawal($p);
    }

    if (my $err = _withdrawal_validation($client, $total + $amount)) {
        return $err;
    }

    return;
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

sub _withdrawal_validation_period {
    my $lc = shift;

    return {
        start_time => Date::Utility->new(time - 86400 * 30),
        exclude    => ['currency_conversion_transfer', 'account_transfer'],
        }
        if $lc eq 'iom';

    return {
        exclude => ['currency_conversion_transfer', 'account_transfer'],
    } if $lc eq 'malta';

    return;
}

sub _withdrawal_validation {
    my ($client, $total) = @_;

    my ($lc, $is_authenticated) = ($client->landing_company->short, $client->fully_authenticated);

    return _create_error(localize('Account needs age verification.')) if ($lc =~ /^(?:malta|iom)$/ and not $client->status->age_verification);
    return _create_error(localize('Please authenticate your account.')) if ($lc eq 'iom'   and not $is_authenticated and $total >= 3000);
    return _create_error(localize('Please authenticate your account.')) if ($lc eq 'malta' and not $is_authenticated and $total >= 2000);

    return;
}

sub _create_error {
    my ($message, $code, $details) = @_;

    return {
        error => {
            code              => $code // 'CashierForwardError',
            message_to_client => $message,
            $details ? (details => $details) : (),
        }};
}

1;
