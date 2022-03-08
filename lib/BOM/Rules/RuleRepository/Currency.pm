package BOM::Rules::RuleRepository::Currency;

=head1 NAME

BOM::Rules::RuleRepositry::Currency

=head1 DESCRIPTION

This modules declares rules and regulations concerning client's account currency.

=cut

use strict;
use warnings;

use Syntax::Keyword::Try;
use List::Util qw(any);

use BOM::Rules::Registry qw(rule);
use BOM::Config::CurrencyConfig;

rule 'currency.is_currency_suspended' => {
    description => "Fails if currency is suspended or invalid; otherwise passes.",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 unless $args->{currency};
        my $currency = $args->{currency};

        my $type = LandingCompany::Registry::get_currency_type($currency);

        return 1 if $type eq 'fiat';

        my $error;
        try {
            $error = 'CurrencySuspended'
                if BOM::Config::CurrencyConfig::is_crypto_currency_suspended($currency);
        } catch {
            $error = 'InvalidCryptoCurrency';
        };

        $self->fail(
            $error,
            params => $currency,
        ) if $error;

        return 1;
    },
};

rule 'currency.experimental_currency' => {
    description => "Fails the currency is experimental and the client's email is not whitlisted for experimental currencies.",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 unless exists $args->{currency};

        if (BOM::Config::CurrencyConfig::is_experimental_currency($args->{currency})) {
            my $allowed_emails = BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed;
            my $client_email   = $context->client($args)->email;

            $self->fail('ExperimentalCurrency') if not any { $_ eq $client_email } @$allowed_emails;
        }

        return 1;
    },
};

rule 'currency.no_real_mt5_accounts' => {
    description => "Currency cannot be changed if there's any existing real MT5 account.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        return 1 unless exists $args->{currency};

        $self->fail('MT5AccountExisting')
            if $client->account() && $client->user->mt5_logins('real');

        return 1;
    },
};

rule 'currency.no_real_dxtrade_accounts' => {
    description => "Currency cannot be changed if there's any existing Deriv X account.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        return 1 unless exists $args->{currency};

        die {code => 'DXTradeAccountExisting'}
            if $client->account() && $client->user->dxtrade_loginids('real');

        return 1;
    },
};

rule 'currency.has_deposit_attempt' => {
    description => "Fails if client attempted a deposit; checked on existing currency.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        $self->fail('DepositAttempted')
            if $client->status->deposit_attempt;

        return 1;
    },
};

rule 'currency.no_deposit' => {
    description => "Fails if client's account has some deposit; checked on exiting currency.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        $self->fail('AccountWithDeposit')
            if $client->has_deposits();

        return 1;
    },
};

rule 'currency.account_is_not_crypto' => {
    description => "Fails if the client's account is crypto",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        $self->fail('CryptoAccount')
            if LandingCompany::Registry::get_currency_type($client->currency() // '') eq 'crypto';

        return 1;
    },
};

=head2 _currency_is_available

Checks if the requested currency is available for account opening or currency change.
Currency should not be taken by any sibling of the same landing company. There's only one fiat currency allowed for trading sibling accounts.
Arguments:

=over 4

=item $context: rule engine context object

=item args: action args as a hashref, containing the requested currency 

=item include_self: if true, the context client will be included in the siblings (useful for account opening); otherwise it will be excluded (used for changing currency of an existing account).

=back

=cut

sub _currency_is_available {
    my ($self, $context, $args, $include_self) = @_;

    my $currency        = $args->{currency};
    my $currency_type   = LandingCompany::Registry::get_currency_type($currency);
    my $account_type    = $args->{account_type}    // $context->client($args)->account_type;
    my $payment_method  = $args->{payment_method}  // '';
    my $landing_company = $args->{landing_company} // $context->client($args)->landing_company->short;

    return 1 unless $currency;

    my @siblings = values $context->client($args)->real_account_siblings_information(
        exclude_disabled_no_currency => 1,
        include_self                 => $include_self
    )->%*;

    for my $sibling (@siblings) {
        next if $account_type ne $sibling->{account_type};

        # Note: Landing company is matched for trading acccounts only.
        #       Wallet landing company is skipped to avoid failure when we switch from samoa to svg.
        next if $account_type eq 'trading' and $sibling->{landing_company_name} ne $landing_company;

        # Only one fiat trading account is allowed
        if ($account_type eq 'trading' && $currency_type eq 'fiat') {
            my $sibling_currency_type = LandingCompany::Registry::get_currency_type($sibling->{currency});
            $self->fail('CurrencyTypeNotAllowed') if $sibling_currency_type eq 'fiat';
        }

        my $error_code = $sibling->{account_type} eq 'trading' ? 'DuplicateCurrency' : 'DuplicateWallet';
        # Account type, currency and payment method should match
        my $sibling_payment_method = $sibling->{payment_method} // '';

        $self->fail($error_code, params => $currency)
            if $account_type eq $sibling->{account_type}
            and $currency eq ($sibling->{currency} // '')
            and $payment_method eq $sibling_payment_method;
    }

    return 1;
}

rule 'currency.is_available_for_new_account' => {
    description => "Succeeds if the selected currency is available for account opening.",
    code        => sub {
        my ($self, $context, $args) = @_;

        return _currency_is_available($self, $context, $args, 1),;
    },
};

rule 'currency.is_available_for_change' => {
    description => "Succeeds if the selected currency is not used by another sibling account.",
    code        => sub {
        my ($self, $context, $args) = @_;

        return _currency_is_available($self, $context, $args, 0),;
    },
};

rule 'currency.known_currencies_allowed' => {
    description => "Only known currencies are allowed.",
    code        => sub {
        my ($self, $context, $args) = @_;
        $self->fail('IncompatibleCurrencyType') unless LandingCompany::Registry::get_currency_type($args->{currency});
        return 1;
    },
};

rule 'currency.account_currency_is_legal' => {
    description => "Checks if all account currencies should be legal in it's landing company",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client          = $context->client({loginid => $args->{loginid}});
        my $landing_company = $client->landing_company;
        my $currency        = $client->currency;
        $self->fail('CurrencyNotLegalLandingCompany') if (not $landing_company->is_currency_legal($currency));

        return 1;
    },
};
1;
