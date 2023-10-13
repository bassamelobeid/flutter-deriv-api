package BOM::Rules::RuleRepository::Transfers;

=head1 NAME

BOM::Rules::RuleRepository::Transfers

=head1 DESCRIPTION

This modules declares rules and regulations concerning transfers between accounts

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);
use BOM::Config::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Config::CurrencyConfig;
use BOM::Config::AccountType::Registry;

use Format::Util::Numbers qw(formatnumber financialrounding);
use Scalar::Util          qw( looks_like_number );
use Syntax::Keyword::Try;
use List::Util qw/any all/;
use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw/convert_currency offer_to_clients/;

rule 'transfers.currency_should_match' => {
    description => "The currency of the account given should match the currency param when defined",
    code        => sub {
        my ($self, $context, $args) = @_;

        # currency param is renamed to request_currency when invoking rule.
        # only transfer_between_accounts sends the currency param, trading_platform_* do not send it.
        my $request_currency = $args->{request_currency} // return 1;

        $self->fail('CurrencyShouldMatch') unless $args->{amount_currency} eq $request_currency;

        return 1;
    },
};

rule 'transfers.daily_count_limit' => {
    description => "Validates the daily transfer limits for the context client",
    code        => sub {
        my ($self, $context, $args) = @_;

        my (undef, undef, $user, $client_from, $client_to) = _get_clients_info(@_);

        my $limit_type = $user->get_transfer_limit_type(
            %$args,
            client_from => $client_from,
            client_to   => $client_to
        );
        my $transfer_config = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts;
        my $config_name     = $limit_type->{config_name};

        # daily_cumulative_limit is disabled if it is <= 0
        return 1 if $transfer_config->daily_cumulative_limit->enable && $transfer_config->daily_cumulative_limit->$config_name > 0;

        my $transfer_limit = $transfer_config->limits->$config_name;
        my $transfer_count = $user->daily_transfer_count(
            type       => $limit_type->{type},
            identifier => $limit_type->{identifier});

        $self->fail('MaximumTransfers', params => [$transfer_limit]) unless $transfer_count < $transfer_limit;

        return 1;
    },
};

rule 'transfers.daily_total_amount_limit' => {
    description => "Validates the daily total amount transfer limits for the context client",
    code        => sub {
        my ($self, $context, $args) = @_;

        my (undef, undef, $user, $client_from, $client_to) = _get_clients_info(@_);

        my $limit_type = $user->get_transfer_limit_type(
            %$args,
            client_from => $client_from,
            client_to   => $client_to
        );
        my $config      = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit;
        my $config_name = $limit_type->{config_name};

        return 1 unless $config->enable and $config->$config_name > 0;

        my ($amount, $amount_currency) = $args->@{qw(amount amount_currency)};

        my $transfer_limit  = $config->$config_name;
        my $transfer_amount = $user->daily_transfer_amount(
            type       => $limit_type->{type},
            identifier => $limit_type->{identifier});

        if ($transfer_amount + convert_currency(abs($amount), $amount_currency, 'USD') > $transfer_limit) {
            my $converted_limit = financialrounding('amount', $amount_currency, convert_currency($transfer_limit, 'USD', $amount_currency));
            $self->fail('MaximumAmountTransfers', params => [$converted_limit, $amount_currency]);
        }

        return 1;
    },
};

rule 'transfers.limits' => {
    description => "Validates the minimum and maximum limits for transfers on the given platform",
    code        => sub {
        my ($self, $context, $args) = @_;

        my ($platform, $amount, $amount_currency) = $args->@{qw(platform amount amount_currency)};
        # TODO: better to get the brand name from arguments
        my $brand_name      = request()->brand->name;
        my $transfer_limits = BOM::Config::CurrencyConfig::platform_transfer_limits($platform, $brand_name);

        my $min = $transfer_limits->{$amount_currency}->{min};
        my $max = $transfer_limits->{$amount_currency}->{max};

        die $self->fail(
            'InvalidMinAmount',
            params => [formatnumber('amount', $amount_currency, $min), $amount_currency],
        ) if $amount < financialrounding('amount', $amount_currency, $min);

        $self->fail(
            'InvalidMaxAmount',
            params => [formatnumber('amount', $amount_currency, $max), $amount_currency],
        ) if $amount > financialrounding('amount', $amount_currency, $max);

        return 1;
    },
};

rule 'transfers.experimental_currency_email_whitelisted' => {
    description => "Validate experimental currencies for whitelisted emails",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        if (   BOM::Config::CurrencyConfig::is_experimental_currency($client->account->currency_code)
            or BOM::Config::CurrencyConfig::is_experimental_currency($args->{platform_currency}))
        {
            my $allowed_emails = BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed;

            $self->fail('CurrencyTypeNotAllowed') if not any { $_ eq $client->email } @$allowed_emails;
        }

        return 1;
    },
};

rule 'transfers.landing_companies_are_the_same' => {
    description => "Landing companies should be the same on both sides of the transfer",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $lc_from = $args->{landing_company_from} // $context->landing_company({loginid => $args->{loginid_from}});
        my $lc_to   = $args->{landing_company_to}   // $context->landing_company({loginid => $args->{loginid_to}});
        $self->fail('DifferentLandingCompanies') if $lc_from ne $lc_to;

        return 1;
    },
};

rule 'transfers.real_to_virtual_not_allowed' => {
    description => "Transfer between real and virtual accounts is not allowed",
    code        => sub {
        my ($self, $context, $args) = @_;

        my ($details_from, $details_to) = _get_clients_info(@_);

        $self->fail('RealToVirtualNotAllowed') unless $details_from->{is_virtual} == $details_to->{is_virtual};

        return 1;
    },
};

rule 'transfers.no_different_fiat_currencies' => {
    description => "Transfer between accounts with different fiat currencies is not permitted (fiat currencies should be the same).",
    code        => sub {
        my ($self, $context, $args) = @_;

        my %currencies = _get_currency_info($context, $args);

        $self->fail('DifferentFiatCurrencies')
            if $currencies{from}->{type} eq 'fiat'
            && $currencies{to}->{type} eq 'fiat'
            && $currencies{from}->{code} ne $currencies{to}->{code};

        return 1;
    },
};

rule 'transfers.same_account_not_allowed' => {
    description => "Transfer to the same account is not allowed",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('SameAccountNotAllowed') if ($args->{loginid_from} eq $args->{loginid_to});

        return 1;
    },
};

rule 'transfers.crypto_exchange_rates_availability' => {
    description => "Exchange rates should be available when transferring to or from crypto.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my %currencies = _get_currency_info($context, $args);

        # no exchange rate are needed for same-currency transfers
        return 1 if $currencies{from}->{code} eq $currencies{to}->{code};

        for (qw/from to/) {
            next if $currencies{$_}->{type} ne 'crypto';

            my $currency = $currencies{$_}->{code};

            $self->fail('ExchangeRatesUnavailable', params => $currency) unless ExchangeRates::CurrencyConverter::offer_to_clients($currency);
        }

        return 1;
    },
};

rule 'transfers.clients_are_not_transfer_blocked' => {
    description => "Fails any of the clients is transfer-blocked (the rule always passes if the currency types are the same)",
    code        => sub {
        my ($self, $context, $args) = @_;

        my %currencies = _get_currency_info($context, $args);

        return 1 if $currencies{from}->{type} eq $currencies{to}->{type};

        $self->fail('TransferBlocked')
            if $context->client({loginid => $args->{loginid_from}})->status->transfers_blocked
            || $context->client({loginid => $args->{loginid_to}})->status->transfers_blocked;

        return 1;
    },
};

rule 'transfers.client_loginid_client_from_loginid_mismatch' => {
    description => "Client loginid and client_from loginid are not the same unless token type is oauth or its virtual transfer",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client      = $context->client({loginid => $args->{loginid}});
        my $client_from = $context->client({loginid => $args->{loginid_from}});

        $self->fail('IncompatibleClientLoginidClientFrom')
            if ($args->{loginid} ne $args->{loginid_from})
            and ($args->{token_type} ne 'oauth_token');

        return 1;
    },
};

rule 'transfers.same_landing_companies' => {
    description => "Landing companies should be the same",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client_to   = $context->client({loginid => $args->{loginid_to}});
        my $client_from = $context->client({loginid => $args->{loginid_from}});
        my ($lc_from, $lc_to) = ($client_from->landing_company, $client_to->landing_company);
        # Transfers within landing company are allowed
        return 1 if $lc_from->short eq $lc_to->short;
        # Transfers between wallet and trading app are allowed
        return 1 if $client_from->is_wallet or $client_to->is_wallet;
        # Transfers  between malta  and maltainvest are fine
        return 1 if ($lc_from->short =~ /^(?:malta|maltainvest)$/ and $lc_to->short =~ /^(?:malta|maltainvest)$/);
        $self->fail('IncompatibleLandingCompanies');
    },
};

rule 'transfers.amount_is_valid' => {
    description => "checking if amount is positive and has numeric value",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('TransferInvalidAmount') unless (looks_like_number($args->{amount}) and $args->{amount} > 0);

        return 1;
    },
};

rule 'transfers.account_type_capability' => {
    description => 'Transfer must be supported by account type.',
    code        => sub {
        my ($self, $context, $args) = @_;

        my ($details_from, $details_to) = _get_clients_info(@_);

        return 1 unless $details_from->{is_wallet} and $details_to->{is_wallet};

        $self->fail('TransferBlockedWalletWithdrawal') unless $details_from->{account_type_obj}->transfers =~ /^(all|withdrawal)$/;
        $self->fail('TransferBlockedWalletDeposit')    unless $details_to->{account_type_obj}->transfers   =~ /^(all|deposit)$/;

        return 1;
    },
};

rule 'transfers.between_trading_accounts' => {
    description => 'Transfers between trading accounts are not allowed.',
    code        => sub {
        my ($self, $context, $args) = @_;

        my ($details_from, $details_to) = _get_clients_info(@_);

        # binary accounts are not considered "trading" for this check
        my $from_is_trading = ($details_from->{account_type_obj}->name eq 'standard' or $details_from->{is_external}) ? 1 : 0;
        my $to_is_trading   = ($details_to->{account_type_obj}->name eq 'standard'   or $details_to->{is_external})   ? 1 : 0;

        $self->fail('TransferBlockedTradingAccounts') if $from_is_trading and $to_is_trading;

        return 1;
    },
};

rule 'transfers.wallet_links' => {
    description => 'Transfers to/from a linked trading account must be with the linked wallet.',
    code        => sub {
        my ($self, $context, $args) = @_;

        my ($details_from, $details_to) = _get_clients_info(@_);

        return 1 if all { $_->{is_wallet} } ($details_from, $details_to);

        # If to account is linked to wallet, from account must be the wallet
        $self->fail('TransferBlockedWalletNotLinked') if $details_to->{wallet_loginid} and $details_to->{wallet_loginid} ne $args->{loginid_from};

        # If from account is linked to wallet, to account must be the wallet
        $self->fail('TransferBlockedWalletNotLinked') if $details_from->{wallet_loginid} and $details_from->{wallet_loginid} ne $args->{loginid_to};

        # If from account is a wallet, to account must be linked to it
        $self->fail('TransferBlockedWalletNotLinked')
            if $details_from->{is_wallet} and ($details_to->{wallet_loginid} // '') ne $args->{loginid_from};

        # If to account is a wallet, from account must be linked to it
        $self->fail('TransferBlockedWalletNotLinked') if $details_to->{is_wallet} and ($details_from->{wallet_loginid} // '') ne $args->{loginid_to};

        return 1;
    },
};

rule 'transfers.legacy_and_wallet' => {
    description => 'Cannot transfer between a legacy (binary) account and wallet',
    code        => sub {
        my ($self, $context, $args) = @_;

        my ($details_from, $details_to) = _get_clients_info(@_);

        # if from account is legacy, to account cannot be wallet
        $self->fail('TransferBlockedLegacy')
            if $details_from->{account_type_obj}->name eq BOM::Config::AccountType::LEGACY_TYPE and $details_to->{is_wallet};

        # if to account is legacy, from account cannot be wallet
        $self->fail('TransferBlockedLegacy')
            if $details_to->{account_type_obj}->name eq BOM::Config::AccountType::LEGACY_TYPE and $details_from->{is_wallet};

        return 1;
    },
};

rule 'transfers.authorized_client_is_legacy_virtual' => {
    description => 'Authorized client cannot be a legacy binary VR account.',
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);

        $self->fail('TransferBlockedClientIsVirtual') if $client->is_virtual and $client->is_legacy;

        return 1;
    },
};

=head2 _get_currency_info

Returns a hash containing the currency code and type for each party involved in the transfer.
It takes the following arguments:

=over 4

=item * C<context> - the rule engine context object

=item * C<args> - action arguments as a hash-ref that contains B<loginid_from> and B<loginid_to>

=back

=cut

sub _get_currency_info {
    my ($context, $args) = @_;

    my %currencies;
    for (qw/from to/) {
        my $loginid = $args->{"loginid_$_"};
        die "Agrument loginid_$_ is missing" unless $loginid;

        my $client   = $context->client({loginid => $loginid});
        my $currency = $client->account->currency_code;

        $currencies{$_}->{code} = $currency;
        $currencies{$_}->{type} = LandingCompany::Registry::get_currency_type($currency);
    }

    return %currencies;
}

=head2 _get_clients_info

Gets client data from loginid_from and loginid_to arguments.

=over 4

=item * C<context> - the rule engine context object

=item * C<args> - action arguments as a hash-ref that contains B<loginid_from> and B<loginid_to>

=back

=cut

sub _get_clients_info {
    my ($self, $context, $args) = @_;

    my $user    = $context->user;
    my $details = $user->loginid_details;

    my $details_from = $details->{$args->{loginid_from}} or $self->fail('PermissionDenied');
    my $details_to   = $details->{$args->{loginid_to}}   or $self->fail('PermissionDenied');

    my $client_from = $details_from->{is_external} ? undef : $context->client({loginid => $args->{loginid_from}});
    my $client_to   = $details_to->{is_external}   ? undef : $context->client({loginid => $args->{loginid_to}});

    $details_from->{account_type_obj} =
          $client_from
        ? $client_from->get_account_type
        : BOM::Config::AccountType::Registry->account_type_by_name($details_from->{platform});

    $details_to->{account_type_obj} =
          $client_to
        ? $client_to->get_account_type
        : BOM::Config::AccountType::Registry->account_type_by_name($details_to->{platform});

    return ($details_from, $details_to, $user, $client_from, $client_to);
}

1;
