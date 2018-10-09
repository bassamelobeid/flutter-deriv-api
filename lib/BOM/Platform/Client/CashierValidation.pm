package BOM::Platform::Client::CashierValidation;

=head1 NAME

BOM::Platform::Client::CashierValidation

=head1 DESCRIPTION

Handles validation for cashier

=cut

use strict;
use warnings;

use Date::Utility;
use Scalar::Util qw(looks_like_number);
use ExchangeRates::CurrencyConverter qw/convert_currency/;

use Brands;
use BOM::User::Client;
use LandingCompany::Registry;

use BOM::Config::Runtime;
use BOM::Platform::Context qw/request localize/;

=head2 validate

Validates various checks related to cashier including
regulation, compliance requirements

=cut

sub validate {
    my ($loginid, $action) = @_;

    return _create_error(localize('Sorry, cashier is temporarily unavailable due to system maintenance.'))
        if (is_payment_suspended());

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
    return _create_error(localize('Your cashier is locked.'))                     if ($client->status->cashier_locked);
    return _create_error(localize('Your account is disabled.'))                   if ($client->status->disabled);
    return _create_error(localize('Your cashier is locked as per your request.')) if ($client->cashier_setting_password);

    my $landing_company = $client->landing_company;
    return _create_error(localize('[_1] transactions may not be performed with this account.', $currency))
        unless ($landing_company->is_currency_legal($currency));

    return _create_error(
        localize(
            'Your identity documents have passed their expiration date. Kindly send a scan of a valid identity document to [_1] to unlock your cashier.',
            Brands->new(name => request()->brand)->emails('support'))) if ($client->documents_expired);

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

    if ($client->landing_company->short ne 'maltainvest' && $client->residence eq 'gb') {
        return _create_error(localize('Please accept Funds Protection.'), 'ASK_UK_FUNDS_PROTECTION')
            unless $client->status->ukgc_funds_protection;
        return _create_error(localize('Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.'),
            'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET')
            if $client->status->ukrts_max_turnover_limit_not_set;
    }
    # action specific validation should be last to be validated
    return _create_error(localize('Your account is restricted to withdrawals only.'))
        if ($action eq 'deposit' and $client->status->unwelcome);

    return _create_error(localize('Your account is locked for withdrawals.'))
        if ($action eq 'withdraw' and $client->status->withdrawal_locked);

    return;
}

=head2 is_payment_suspended

Returns whether payment is currently suspended or not

=cut

sub is_payment_suspended {
    return BOM::Config::Runtime->instance->app_config->system->suspend->payments;
}

=head2 is_crypto_cashier_suspended

Returns whether crypto cashier is currently suspended or not

=cut

sub is_crypto_cashier_suspended {
    return BOM::Config::Runtime->instance->app_config->system->suspend->cryptocashier;
}

=head2 is_crypto_currency_suspended {

Returns true if the given currency is suspended in the crypto cashier. Only works for crypto currencies,
this will die for fiat currencies such as USD / GBP.

=cut

sub is_crypto_currency_suspended {
    my $currency = shift or die "expected currency parameter";

    die "Failed to accept $currency as a cryptocurrency." if (LandingCompany::Registry::get_currency_type(uc $currency) // '') ne 'crypto';

    return 1 if BOM::Config::Runtime->instance->app_config->system->suspend->cryptocashier;

    return BOM::Config::Runtime->instance->app_config->system->suspend->cryptocurrencies =~ /\Q$currency\E/;
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

sub calculate_to_amount_with_fees {
    my ($fm_client, $to_client, $amount, $from_currency, $to_currency, $rate_expiry) = @_;

    # need to calculate fees only when currency type are different
    my ($fees, $fees_percent) = (0, 0);

    my $from_currency_type = LandingCompany::Registry::get_currency_type($from_currency);
    my $to_currency_type   = LandingCompany::Registry::get_currency_type($to_currency);

    # need to calculate fees only when currency type are different
    # as MF (USD) to MLT (USD) is posssible, we charges zero when that happens
    if (($from_currency_type ne $to_currency_type) and ($from_currency ne $to_currency)) {

        # contains a pa agent account, and has no unauthorized payment agent account and it is the same user
        if ($fm_client->is_same_user_as($to_client) && ($fm_client->is_pa_and_authenticated() || $to_client->is_pa_and_authenticated())) {
            # no fees for authenticate payment agent
            $fees = 0;
        } else {
            my $transfer_config = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts;
            my $landing_company = LandingCompany::Registry::get_currency_type($from_currency);
            $fees_percent = $transfer_config->fees->$landing_company;
            $fees = ($amount) * ($fees_percent / 100);
        }

        $amount -= $fees;
        $amount = convert_currency($amount, $from_currency, $to_currency, $rate_expiry);
    }

    return ($amount, $fees, $fees_percent);
}

sub _withdrawal_validation_period {
    my $lc = shift;

    return {
        start_time => Date::Utility->new(time - 86400 * 30),
        exclude    => ['currency_conversion_transfer'],
    } if $lc eq 'iom';

    return {
        exclude => ['currency_conversion_transfer'],
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
    my ($message, $code) = @_;

    return {
        error => {
            code => $code // 'CashierForwardError',
            message_to_client => $message
        }};
}

1;
