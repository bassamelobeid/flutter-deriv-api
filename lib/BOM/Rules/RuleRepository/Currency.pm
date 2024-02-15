package BOM::Rules::RuleRepository::Currency;

=head1 NAME

BOM::Rules::RuleRepository::Currency

=head1 DESCRIPTION

This modules declares rules and regulations concerning client's account currency.

=cut

use strict;
use warnings;

use Syntax::Keyword::Try;
use List::Util qw(any);

use BOM::Rules::Registry qw(rule);
use BOM::Config::CurrencyConfig;
use BOM::Config::AccountType;

use Carp;

use Carp;

rule 'currency.is_currency_suspended' => {
    description => "Fails if currency is suspended or invalid; otherwise passes.",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 unless $args->{currency};
        my $currency = $args->{currency};

        my $type = LandingCompany::Registry::get_currency_type($currency);

        return 1 if $type eq 'fiat';

        my $error;
        my $description;
        try {
            $error = 'CurrencySuspended'
                if BOM::Config::CurrencyConfig::is_crypto_currency_suspended($currency);
            $description = "Currency $currency is suspended";
        } catch {
            $error       = 'InvalidCryptoCurrency';
            $description = "Currency $currency is invalid";
        };

        $self->fail(
            $error,
            params      => $currency,
            description => $description
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

            $self->fail('ExperimentalCurrency', description => 'Experimental currency is not allowed for client')
                if not any { $_ eq $client_email } @$allowed_emails;
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
            if $client->account() && $client->user->get_mt5_loginids(type_of_account => 'real');

        return 1;
    },
};

rule 'currency.no_real_dxtrade_accounts' => {
    description => "Currency cannot be changed if there's any existing Deriv X account.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        return 1 unless exists $args->{currency};

        $self->fail('DXTradeAccountExisting')
            if $client->account() && $client->user->get_dxtrade_loginids(type_of_account => 'real');

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

=item configuration: contains include_self && reactivate settings

include_self: if true, the context client will be included in the siblings (useful for account opening); otherwise it will be excluded (used for changing currency of an existing account).

reactivate: indicates if the rule is checked for reactivation, in which case only active accounts will be checked.

=back

=cut

sub _currency_is_available {
    my ($self, $context, $args, $configuration) = @_;
    my $currency         = $args->{currency};
    my $currency_type    = LandingCompany::Registry::get_currency_type($currency);
    my $account_type     = $args->{account_type} // $context->client($args)->get_account_type->name;
    my $account_category = BOM::Config::AccountType::Registry->account_type_by_name($account_type)->category->name;
    my $landing_company  = $args->{landing_company}       // $context->client($args)->landing_company->short;
    my $include_self     = $configuration->{include_self} // 0;
    my $reactivate       = $configuration->{reactivate}   // 0;

    return 1 unless $currency;

    my $cached_siblings = $context->client_siblings($args);
    my @siblings =
        (ref $cached_siblings eq 'ARRAY')
        ? $cached_siblings->@*
        : values $context->client($args)->real_account_siblings_information(
        exclude_disabled_no_currency => 1,
        include_duplicated           => 1,
        include_self                 => $include_self
    )->%*;

    for my $sibling (@siblings) {

        next if $account_category ne $sibling->{category};
        my $sibling_duplicate = $sibling->{duplicate} // 0;

        # If we are reactivating an account, currency should be checked against active siblings only.
        next if $reactivate && ($sibling->{disabled} || $sibling->{duplicate});

        next if $sibling->{landing_company_name} ne $landing_company;

        # Only one fiat account is allowed per landing company
        if ($account_category eq 'trading' && $currency_type eq 'fiat' && !$sibling_duplicate) {
            my $sibling_currency_type = LandingCompany::Registry::get_currency_type($sibling->{currency});
            $self->fail('CurrencyTypeNotAllowed', description => 'Currency type is not allowed')
                if ($sibling_currency_type eq 'fiat' && $currency ne $sibling->{currency});
        }

        if ($account_category eq 'wallet' && $currency_type eq 'fiat' && $account_type eq 'doughflow') {
            my $sibling_currency_type = LandingCompany::Registry::get_currency_type($sibling->{currency});
            $self->fail('CurrencyTypeNotAllowed', description => 'Currency type is not allowed')
                if ($sibling_currency_type eq 'fiat' && $sibling->{account_type} eq 'doughflow' && $currency ne $sibling->{currency});
        }

        my $sibling_account_category = $sibling->{category} // '';
        my $error_code               = $sibling_account_category eq 'trading' ? 'DuplicateCurrency'           : 'DuplicateWallet';
        my $error_desc               = $sibling_account_category eq 'trading' ? 'Duplicate currency detected' : 'Duplicate wallet detected';
        my $sibling_account_type     = $sibling->{account_type} // '';

        # Accounts of the same currency are not acceptable (duplicate accounts included)
        # Account type, currency and account category should match
        $self->fail(
            $error_code,
            params      => $currency,
            description => $error_desc
            )
            if $account_category eq $sibling_account_category
            and $currency eq ($sibling->{currency} // '')
            and $account_type eq $sibling_account_type;
    }

    return 1;
}

rule 'currency.is_available_for_new_account' => {
    description => "Succeeds if the selected currency is available for account opening.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $currency = $args->{currency};

        my $account_type = BOM::Config::AccountType::Registry->account_type_by_name($args->{account_type} // BOM::Config::AccountType::LEGACY_TYPE);

        if ($account_type->name eq 'binary') {
            return _currency_is_available($self, $context, $args, {include_self => 1});
        } elsif ($account_type->category->name eq 'trading') {
            my $wallet_currency = $context->client({loginid => $args->{loginid}})->default_account->currency_code;

            $self->fail('CurrencyNotAllowed') unless $wallet_currency eq $currency;

            return 1;
        } elsif ($account_type->category->name eq 'wallet') {
            my $landing_company = $args->{landing_company} // $context->client($args)->landing_company->short;
            $self->fail('CurrencyNotAllowed') unless any { $_ eq $currency } $account_type->get_currencies($landing_company)->@*;
            return _currency_is_available($self, $context, $args, {include_self => 1});
        } else {
            #How do we get here?
            confess "Unexpected account type $args->{account_type}";
        }
    },
};

rule 'currency.is_available_for_change' => {
    description => "Succeeds if the selected currency is not used by another sibling account.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $currency = $args->{currency};

        my $client = $context->client({loginid => $args->{loginid}});

        my $account_type = $client->get_account_type;

        if ($account_type->name eq 'binary') {
            return _currency_is_available($self, $context, $args, {include_self => 0});
        } elsif (!$client->is_wallet) {
            # We don't allow to change currency for trading accounts, because currency is inherited from wallet account.
            return $self->fail('CurrencyChangeIsNotPossible');
        } else {
            my $landing_company = $args->{landing_company} // $context->client($args)->landing_company->short;
            $self->fail('CurrencyNotAllowed') unless grep { $_ eq $currency } $account_type->get_currencies($landing_company)->@*;

            return _currency_is_available($self, $context, $args, {include_self => 0});
        }
    },
};

rule 'currency.is_available_for_reactivation' => {
    description => "Succeeds if the selected currency does not conflict with active account.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $args->{currency} = $context->client($args)->currency // '';

        return _currency_is_available($self, $context, $args, {reactivate => 1});
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
