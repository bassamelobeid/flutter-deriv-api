package BOM::Rules::RuleRepository::Transfers;

=head1 NAME

BOM::Rules::RuleRepositry::Transfers

=head1 DESCRIPTION

This modules declares rules and regulations concerning transfers between accounts

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);
use BOM::Config::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Config::CurrencyConfig;

use Format::Util::Numbers qw(formatnumber financialrounding);
use Syntax::Keyword::Try;
use List::Util qw/any/;
use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw/offer_to_clients/;

rule 'transfers.currency_should_match' => {
    description => "The currency of the account given should match the currency param when defined",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        # only transfer_between_accounts sends this param, trading_platform_* do not send it
        my $currency = $args->{currency} // return 1;

        my $action = $args->{action} // '';
        my $account_currency;

        if ($action eq 'deposit') {
            $account_currency = $client->account->currency_code;
        } elsif ($action eq 'withdrawal') {
            $account_currency = $args->{platform_currency};
        } else {
            $self->fail('InvalidAction');
        }

        $self->fail('CurrencyShouldMatch') unless ($account_currency // '') eq $currency;

        return 1;
    },
};

rule 'transfers.daily_limit' => {
    description => "Validates the daily transfer limits for the context client",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client                    = $context->client($args);
        my $platform                  = $args->{platform} // '';
        my $daily_transfer_limit      = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->$platform;
        my $user_daily_transfer_count = $client->user->daily_transfer_count($platform);

        $self->fail('MaximumTransfers', message_params => [$daily_transfer_limit]) unless $user_daily_transfer_count < $daily_transfer_limit;

        return 1;
    },
};

rule 'transfers.limits' => {
    description => "Validates the minimum and maximum limits for transfers on the given platform",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);
        # TODO: better to get the brand name from arguments
        my $brand_name      = request()->brand->name;
        my $platform        = $args->{platform} // '';
        my $action          = $args->{action}   // '';
        my $amount          = $args->{amount}   // '';
        my $transfer_limits = BOM::Config::CurrencyConfig::platform_transfer_limits($platform, $brand_name);
        my $source_currency;

        # limit currency / source currency is always the sending account
        if ($action eq 'deposit') {
            $source_currency = $client->account->currency_code;
        } elsif ($action eq 'withdrawal') {
            $source_currency = $args->{platform_currency};
        } else {
            $self->fail('InvalidAction');
        }

        my $min = $transfer_limits->{$source_currency}->{min};
        my $max = $transfer_limits->{$source_currency}->{max};

        die $self->fail(
            'InvalidMinAmount',
            message_params => [formatnumber('amount', $source_currency, $min), $source_currency],
        ) if $amount < financialrounding('amount', $source_currency, $min);

        $self->fail(
            'InvalidMaxAmount',
            message_params => [formatnumber('amount', $source_currency, $max), $source_currency],
        ) if $amount > financialrounding('amount', $source_currency, $max);

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

1;
