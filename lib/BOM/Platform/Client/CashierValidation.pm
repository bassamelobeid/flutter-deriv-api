use strict;
use warnings;

use Brands;
use Client::Account;

use BOM::Platform::Runtime;
use BOM::Platform::Context qw/request localize/;

sub validate {
    my ($loginid, $action) = @_;

    return _create_error('CashierForwardError', localize('Sorry, cashier is temporarily unavailable due to system maintenance.'))
        if (is_system_suspended() or is_payment_suspended());

    my $client = Client::Account->new({loginid => $loginid}) or return _create_error('CashierForwardError', localize('Invalid account.'));

    my $currency = $client->default_account ? $client->default_account->currency_code : '';
    return _create_error('CashierForwardError', localize('Invalid currency.')) unless $currency;

    my $landing_company = $client->landing_company;
    if ($landing_company->short eq 'maltainvest') {
        return _create_error('ASK_AUTHENTICATE', localize('Client is not fully authenticated.')) unless $client->client_fully_authenticated;

        return _create_error('ASK_FINANCIAL_RISK_APPROVAL', localize('Financial Risk approval is required.'))
            unless $client->get_status('financial_risk_approval');

        return _create_error('ASK_TIN_INFORMATION',
            localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.'))
            unless $client->get_status('crs_tin_information');
    }

    if ($client->residence eq 'gb') {
        unless ($client->get_status('ukgc_funds_protection')) {
            return _create_error('ASK_UK_FUNDS_PROTECTION', localize('Please accept Funds Protection.'));
        }

        if ($client->get_status('ukrts_max_turnover_limit_not_set')) {
            return _create_error('ASK_SELF_EXCLUSION_MAX_TURNOVER_SET',
                localize('Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.'));
        }
    }

    if ($client->residence eq 'jp') {
        return _create_error('ASK_JP_KNOWLEDGE_TEST', localize('You must complete the knowledge test to activate this account.'))
            if ($client->get_status('jp_knowledge_test_pending') or $client->get_status('jp_knowledge_test_fail'));

        return _create_error('JP_NOT_ACTIVATION', localize('Account not activated.')) if $client->get_status('jp_activation_pending');

        return _create_error('ASK_AGE_VERIFICATION', localize('Account needs age verification'))
            if (not $client->get_status('age_verification') and not $client->has_valid_documents);
    }

    my $action = $self->action;
    return _create_error('CashierForwardError', localize('Your account is restricted to withdrawals only.'))
        if ($action eq 'deposit' and $client->get_status('unwelcome'));

    return _create_error(
        'CashierForwardError',
        localize(
            'Your identity documents have passed their expiration date. Kindly send a scan of a valid identity document to [_1] to unlock your cashier.',
            Brands->new(name => request()->brand)->emails('support'))) if ($client->documents_expired);

    return _create_error('CashierForwardError', localize('Your cashier is locked.'))                     if ($client->get_status('cashier_locked'));
    return _create_error('CashierForwardError', localize('Your account is disabled.'))                   if ($client->get_status('disabled'));
    return _create_error('CashierForwardError', localize('Your cashier is locked as per your request.')) if ($client->cashier_setting_password);
    return _create_error('CashierForwardError', localize('Your account is locked for withdrawals. Please contact customer service.'))
        if ($action eq 'withdraw' and $client->get_status('withdrawal_locked'));

    return _create_error('CashierForwardError', localize('[_1] transactions may not be performed with this account.', $currency))
        unless ($landing_company->is_currency_legal($currency));

    return {success => 1};
}

sub is_system_suspended {
    return BOM::Platform::Runtime->instance->app_config->system->suspend->system;
}

sub is_payment_suspended {
    return BOM::Platform::Runtime->instance->app_config->system->suspend->payments;
}

sub is_crypto_cashier_suspended {
    return BOM::Platform::Runtime->instance->app_config->system->suspend->cryptocashier;
}

sub _create_error {
    my ($code, $message) = @_;

    return {
        error => {
            code              => $code,
            message_to_client => $message
        }};
}

1;
