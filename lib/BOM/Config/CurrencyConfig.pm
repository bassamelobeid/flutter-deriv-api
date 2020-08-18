package BOM::Config::CurrencyConfig;

=head1 NAME

BOM::Config::CurrencyConfig

=head1 DESCRIPTION

A repository of dynamic configurations set on currencies, like their minimum/maximum limits.

=cut

use strict;
use warnings;
use feature 'state';
no indirect;

use Syntax::Keyword::Try;
use JSON::MaybeUTF8;
use Log::Any qw($log);
use Format::Util::Numbers qw(get_min_unit financialrounding);
use ExchangeRates::CurrencyConverter qw/convert_currency/;
use List::Util qw(any max min);
use LandingCompany::Registry;

use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Finance::Exchange;
use Quant::Framework;
use Locale::Object::Currency;
use Locale::Country;

use constant MAX_TRANSFER_FEE => 7;
require Exporter;
our @EXPORT_OK = qw(MAX_TRANSFER_FEE);

my $_app_config;

#lazy loading $_app_config
sub app_config {
    $_app_config = BOM::Config::Runtime->instance->app_config() unless $_app_config;
    $_app_config->check_for_update();
    return $_app_config;
}

=head2 currency_for_country

Method returns currency code for requested country code.

=cut

#We're loading mapping at startup time to avoid interation with my SQLlite at runtime.

our %LOCAL_CURRENCY_FOR_COUNTRY = do {
    # Locale::Object::Currency emits warnings for any countries it does not have configured, since the source for
    # those countries is different from its database we need to silence those here
    local $SIG{__WARN__} = sub { };

    map {
        $_ => eval { Locale::Object::Currency->new(country_code => $_)->code }
            // undef
    } Locale::Country::all_country_codes();
};

sub local_currency_for_country {
    my ($country_code) = @_;
    return undef unless $country_code;
    return $LOCAL_CURRENCY_FOR_COUNTRY{lc($country_code)};
}

=head2 is_valid_currency

Checks if the currency is valid.

=over 4

=item * C<currency> - The currency code to check the validity of. (case-sensitive)

=back

Returns 1 if currency is valid, otherwise 0.

=cut

sub is_valid_currency {
    my ($currency) = @_;
    return (any { $_ eq $currency } LandingCompany::Registry->new()->all_currencies);
}

=head2 is_valid_crypto_currency

Checks if the crypto currency is valid.

=over 4

=item * C<currency> - The crypto currency code to check the validity of. (case-sensitive)

=back

Returns 1 if currency is valid, otherwise 0.

=cut

sub is_valid_crypto_currency {
    my ($currency) = @_;
    return (any { $_ eq $currency } LandingCompany::Registry->new()->all_crypto_currencies);
}

=head2 transfer_between_accounts_limits

Transfer limits are returned as a {currency => {min => 1, max => 2500}, ... } hash ref.
These values are extracted from app_config->payment.transfer_between_accounts.minimum/maximum editable in backoffice Dynamic Settings page.

=over 4

=item * C<force_refresh> - if true, transfer between accounts will be recalculated (a little expensive); otherwise, use the cached values.

=back

=cut

sub transfer_between_accounts_limits {
    my ($force_refresh) = @_;

    state $currency_limits_cache = {};
    my $loaded_revision = BOM::Config::Runtime->instance->app_config()->loaded_revision // '';
    return $currency_limits_cache
        if (not $force_refresh)
        and $currency_limits_cache->{revision}
        and ($currency_limits_cache->{revision} eq $loaded_revision);

    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $configs = app_config()->get([
        'payments.transfer_between_accounts.minimum.default', 'payments.transfer_between_accounts.minimum.by_currency',
        'payments.transfer_between_accounts.maximum.default'
    ]);

    my $configs_json = JSON::MaybeUTF8::decode_json_utf8($configs->{'payments.transfer_between_accounts.minimum.by_currency'});

    my $currency_limits = {};
    foreach my $currency (@all_currencies) {
        my $min = $configs_json->{$currency} // $configs->{"payments.transfer_between_accounts.minimum.default"};

        $min = eval { financialrounding('amount', $currency, convert_currency($min, 'USD', $currency)); };

        my $max = eval {
            0 + financialrounding('amount', $currency,
                convert_currency($configs->{'payments.transfer_between_accounts.maximum.default'}, 'USD', $currency));
        };

        if (is_valid_crypto_currency($currency) && is_crypto_currency_suspended($currency)) {
            $min = 0 unless $min;
            $max = 0 unless $max;
        }

        $currency_limits->{$currency}->{min} = financialrounding('amount', $currency, $min);
        $currency_limits->{$currency}->{max} = $max if $max;
    }

    $currency_limits->{revision} = $loaded_revision;
    $currency_limits_cache = $currency_limits;

    return $currency_limits;
}

=head2 transfer_between_accounts_fees

Transfer fees are returned as a hashref for all supported currency pairs; e.g. {'USD' => {'BTC' => 1,'EUR' => 0.5, ...}, ... }.
These values are extracted from payment.transfer_between_accounts.fees.by_currency, if not available it defaults to
a value under payment.transfer_between_accounts.fees.default.* that matches the currency types.

=cut

sub transfer_between_accounts_fees {
    state $transfer_fees_cache = {};
    my $loaded_revision = BOM::Config::Runtime->instance->app_config()->loaded_revision // '';
    return $transfer_fees_cache if $transfer_fees_cache->{revision} and ($transfer_fees_cache->{revision} eq $loaded_revision);

    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $configs = app_config()->get([
        'payments.transfer_between_accounts.fees.default.fiat_fiat',   'payments.transfer_between_accounts.fees.default.fiat_crypto',
        'payments.transfer_between_accounts.fees.default.fiat_stable', 'payments.transfer_between_accounts.fees.default.crypto_fiat',
        'payments.transfer_between_accounts.fees.default.stable_fiat', 'payments.transfer_between_accounts.fees.by_currency'
    ]);
    my $fee_by_currency = JSON::MaybeUTF8::decode_json_utf8($configs->{'payments.transfer_between_accounts.fees.by_currency'});

    my $currency_config;
    for my $from_currency (@all_currencies) {
        my $from_def      = LandingCompany::Registry::get_currency_definition($from_currency);
        my $from_category = $from_def->{stable} ? 'stable' : $from_def->{type};

        my $fees;
        foreach my $to_currency (@all_currencies) {
            my $to_def = LandingCompany::Registry::get_currency_definition($to_currency);

            #Same-currency and crypto-to-crypto transfers are not supported: fee = undef.
            unless (($from_def->{type} eq 'crypto' and $to_def->{type} eq 'crypto') or $from_currency eq $to_currency) {
                my $to_category = $to_def->{stable} ? 'stable' : $to_def->{type};
                my $fee         = $fee_by_currency->{"${from_currency}_$to_currency"}
                    // $configs->{"payments.transfer_between_accounts.fees.default.${from_category}_$to_category"};
                if ($fee < 0) {
                    $log->tracef("The %s-%s transfer fee of %d in app_config->payements.transfer_between_accounts.fees was too low. Raised to 0",
                        $from_currency, $to_currency, $fee);
                    $fee = 0;
                }
                if ($fee > MAX_TRANSFER_FEE) {
                    $log->tracef("The %s-%s transfer fee of %d app_config->payements.transfer_between_accounts.fees was too high. Lowered to %d",
                        $from_currency, $to_currency, $fee, MAX_TRANSFER_FEE);
                    $fee = MAX_TRANSFER_FEE;
                }

                $fees->{$to_currency} = 0 + Format::Util::Numbers::roundcommon(0.01, $fee);
            }
        }

        $currency_config->{$from_currency} = $fees;
    }

    $currency_config->{revision} = $loaded_revision;
    $transfer_fees_cache = $currency_config;
    return $currency_config;
}

=head2 rate_expiry

Gets exchange rates quote expiry time for a currency pair.
For fiat currencies, if the FOREX exchange is currently closed, the "fiat_holidays"
app config setting will be used. Otherwise "fiat" is used.
"crypto" is used for crypto currencies.
In the case of different currency types, the shortest expiry time is returned.

=over 4

=item * The source currency we want to convert from.

=item * The target currency we want to convert to.

=back

Returns the allowed age for exchange rate quote in seconds.

=cut

sub rate_expiry {
    my @types  = map { LandingCompany::Registry::get_currency_type($_) } @_;
    my %config = map { $_ => app_config()->get('payments.transfer_between_accounts.exchange_rate_expiry.' . $_) } qw( fiat fiat_holidays crypto );

    my $reader   = BOM::Config::Chronicle::get_chronicle_reader;
    my $calendar = Quant::Framework->new->trading_calendar($reader);
    my $exchange = Finance::Exchange->create_exchange('FOREX');
    my $fiat_key = $calendar->is_open($exchange) ? 'fiat' : 'fiat_holidays';

    my @expiries = map { $config{$_ eq 'fiat' ? $fiat_key : $_} } @types;
    return min(@expiries);
}

=head2 is_payment_suspended

Returns whether payment is currently suspended or not.

=cut

sub is_payment_suspended {
    return app_config()->system->suspend->payments;
}

=head2 is_cashier_suspended

Returns whether fiat cashier is currently suspended or not.

=cut

sub is_cashier_suspended {
    return is_payment_suspended() || app_config()->system->suspend->cashier;
}

=head2 is_crypto_cashier_suspended

Returns whether crypto cashier is currently suspended or not.

=cut

sub is_crypto_cashier_suspended {
    return is_payment_suspended() || app_config()->system->suspend->cryptocashier;
}

=head2 get_suspended_crypto_currencies

Returns a hashref containing the suspended crypto currencies as keys, values are C<1>.

=cut

sub get_suspended_crypto_currencies {
    my @suspended_currencies = split /,/, app_config()->system->suspend->cryptocurrencies;
    s/^\s+|\s+$//g for @suspended_currencies;

    my %suspended_currencies_hash = map { $_ => 1 } @suspended_currencies;

    return \%suspended_currencies_hash;
}

=head2 is_crypto_currency_suspended

To check if the given crypto currency is suspended in the crypto cashier.
Dies when the C<currency> is not provided or not a valid crypto currency.

=over 4

=item * C<currency> - Currency code

=back

Returns 1 if the currency is currently suspended, otherwise 0.

=cut

sub is_crypto_currency_suspended {
    my $currency = shift;

    die 'Expected currency code parameter.' unless $currency;
    die "Failed to accept $currency as a cryptocurrency." unless is_valid_crypto_currency($currency);

    my $suspended_currencies = get_suspended_crypto_currencies();

    return $suspended_currencies->{$currency} ? 1 : 0;
}

=head2 _is_crypto_currency_action_suspended

To check if the specified action for the given crypto currency is suspended
in the crypto cashier.

=over 4

=item * C<currency> - Currency code

=item * C<action> - Action name. Can be one of C<cryptocurrencies_deposit> or C<cryptocurrencies_withdrawal>

=back

Return true if the C<currency> is currently suspended for the C<action>.

=cut

sub _is_crypto_currency_action_suspended {
    my ($currency, $action) = @_;

    return 1 if is_crypto_currency_suspended($currency);

    return any { $currency eq $_ } app_config()->system->suspend->$action->@*;
}

=head2 is_crypto_currency_deposit_suspended

To check if deposit for the given crypto currency is suspended in the crypto cashier.

=over 4

=item * C<currency> - Currency code

=back

Return true if the currency is currently suspended for deposit.

=cut

sub is_crypto_currency_deposit_suspended {
    my $currency = shift;

    return _is_crypto_currency_action_suspended($currency, 'cryptocurrencies_deposit');
}

=head2 is_crypto_currency_withdrawal_suspended

To check if withdrawal for the given crypto currency is suspended in the crypto cashier.

=over 4

=item * C<currency> - Currency code

=back

Return true if the currency is currently suspended for withdrawal.

=cut

sub is_crypto_currency_withdrawal_suspended {
    my $currency = shift;

    return _is_crypto_currency_action_suspended($currency, 'cryptocurrencies_withdrawal');
}

=head2 is_experimental_currency

To check if the currency is experimental.

=over 4

=item * C<currency> - Currency code

=back

Returns true if the currency is experimental.

=cut

sub is_experimental_currency {
    my $currency = shift;

    return any { $currency eq $_ } app_config()->system->suspend->experimental_currencies->@*;
}

1;
