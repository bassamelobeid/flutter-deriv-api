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
use Postgres::FeedDB::CurrencyConverter qw/amount_from_to_currency/;

use Brands;
use Client::Account;
use LandingCompany::Registry;

use BOM::Platform::Runtime;
use BOM::Platform::Context qw/request localize/;

=head2 validate

Validates various checks related to cashier including
regulation, compliance requirements

=cut

sub validate {
    my ($loginid, $action) = @_;

    return _create_error(localize('Sorry, cashier is temporarily unavailable due to system maintenance.'))
        if (is_system_suspended() or is_payment_suspended());

    my $client = Client::Account->new({
            loginid      => $loginid,
            db_operation => 'replica'
        }) or return _create_error(localize('Invalid account.'));

    return _create_error(localize('This is a virtual-money account. Please switch to a real-money account to access cashier.'))
        if $client->is_virtual;

    # for self excluded clients we only allow withdrawal
    if ($action eq 'deposit') {
        my $lim = $client->get_self_exclusion_until_date;
        return _create_error(localize('Sorry, you have excluded yourself until [_1].', $lim), 'SelfExclusion') if $lim;
    }

    my $currency = $client->default_account ? $client->default_account->currency_code : '';
    return _create_error(localize('Please set the currency.'), 'ASK_CURRENCY') unless $currency;

    return _create_error(localize('Please set your country of residence.')) unless $client->residence;

    # better to do generic error validation before landing company or account specific
    return _create_error(localize('Your cashier is locked.'))                     if ($client->get_status('cashier_locked'));
    return _create_error(localize('Your account is disabled.'))                   if ($client->get_status('disabled'));
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
        return _create_error(localize('Please authenticate your account.'), 'ASK_AUTHENTICATE') unless $client->client_fully_authenticated;

        return _create_error(localize('Financial Risk approval is required.'), 'ASK_FINANCIAL_RISK_APPROVAL')
            unless $client->get_status('financial_risk_approval');

        return _create_error(
            localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.'),
            'ASK_TIN_INFORMATION')
            unless $client->get_status('crs_tin_information');
    }

    if ($client->residence eq 'gb' and not $client->get_status('ico_only')) {
        return _create_error(localize('Please accept Funds Protection.'), 'ASK_UK_FUNDS_PROTECTION')
            unless $client->get_status('ukgc_funds_protection');
        return _create_error(localize('Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.'),
            'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET')
            if $client->get_status('ukrts_max_turnover_limit_not_set');
    }

    if ($client->residence eq 'jp') {
        return _create_error(localize('You must complete the knowledge test to activate this account.'), 'ASK_JP_KNOWLEDGE_TEST')
            if ($client->get_status('jp_knowledge_test_pending') or $client->get_status('jp_knowledge_test_fail'));

        return _create_error(localize('Account not activated.'), 'JP_NOT_ACTIVATION') if $client->get_status('jp_activation_pending');

        return _create_error(localize('Account needs age verification.'), 'ASK_AGE_VERIFICATION')
            if (not $client->get_status('age_verification') and not $client->has_valid_documents);
    }

    # action specific validation should be last to be validated
    return _create_error(localize('Your account is restricted to withdrawals only.'))
        if ($action eq 'deposit' and $client->get_status('unwelcome'));

    return _create_error(localize('Your account is locked for withdrawals.'))
        if ($action eq 'withdraw' and $client->get_status('withdrawal_locked'));

    return;
}

=head2 is_system_suspended

Returns whether system is currently suspended or not

=cut

sub is_system_suspended {
    return BOM::Platform::Runtime->instance->app_config->system->suspend->system;
}

=head2 is_payment_suspended

Returns whether payment is currently suspended or not

=cut

sub is_payment_suspended {
    return BOM::Platform::Runtime->instance->app_config->system->suspend->payments;
}

=head2 is_crypto_cashier_suspended

Returns whether crypto cashier is currently suspended or not

=cut

sub is_crypto_cashier_suspended {
    return BOM::Platform::Runtime->instance->app_config->system->suspend->cryptocashier;
}

=head2 is_crypto_currency_suspended {

Returns true if the given currency is suspended in the crypto cashier. Only works for crypto currencies,
this will return false for currencies such as USD / GBP.

=cut

sub is_crypto_currency_suspended {
    my $currency = shift or die "expected currency parameter";
    return 1 if BOM::Platform::Runtime->instance->app_config->system->suspend->cryptocashier;
    return 1 if grep { $currency eq $_ } split /,/, BOM::Platform::Runtime->instance->app_config->system->suspend->cryptocurrencies;
    return 0;
}

=head2 pre_withdrawal_validation

Validates withdrawal amount

Used to validate withdrawal request before forwarding
to external cashiers

As of now doughflow have these checks in their code
but EPG and crypto cashier need it explicitly

=cut

sub pre_withdrawal_validation {
    my ($loginid, $amount) = @_;

    return _create_error(localize('Invalid amount.')) if (not $amount or not looks_like_number($amount) or $amount <= 0);

    my $client = Client::Account->new({
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

# From fiat currency to cryptocurrency: 1% fee
# From cryptocurrency to fiat currency: 0.5% fee
# for an approved PA, we don't need to charge any
# % fee for converting BTC to USD only
sub calculate_to_amount_with_fees {
    my ($loginid, $amount, $from_currency, $to_currency) = @_;

    my $from_currency_type = LandingCompany::Registry::get_currency_type($from_currency);
    my $to_currency_type   = LandingCompany::Registry::get_currency_type($to_currency);

    # need to calculate fees only when currency type are different and
    # currencies are different, we don't allow transfer between same
    # currency type
    my ($fees, $fees_percent) = (0, 0);
    if (($from_currency_type ne $to_currency_type) and ($from_currency ne $to_currency)) {
        my $client = Client::Account->new({
                loginid      => $loginid,
                db_operation => 'replica'
            }) or return ();

        if ($from_currency_type eq 'crypto' and $client->payment_agent and $client->payment_agent->is_authenticated) {
            # no fees for authenticate payment agent
            $fees = 0;
        } else {
            $fees_percent = BOM::Platform::Runtime->instance->app_config->payments->transfer_between_accounts->fees->$from_currency_type;
            $fees = ($amount) * ($fees_percent / 100);
        }

        $amount -= $fees;
        $amount = amount_from_to_currency($amount, $from_currency, $to_currency);
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

    my ($lc, $is_authenticated) = ($client->landing_company->short, $client->client_fully_authenticated);

    return _create_error(localize('Account needs age verification.')) if ($lc =~ /^(?:malta|iom)$/ and not $client->get_status('age_verification'));
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
