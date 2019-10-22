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

use Try::Tiny;
use JSON::MaybeUTF8;
use Log::Any qw($log);
use Format::Util::Numbers qw(get_min_unit financialrounding);
use ExchangeRates::CurrencyConverter qw/convert_currency/;
use List::Util qw(max min);
use LandingCompany::Registry;

use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Finance::Exchange;
use Quant::Framework;

use constant MAX_TRANSFER_FEE => 7;
require Exporter;
our @EXPORT_OK = qw(MAX_TRANSFER_FEE);

my $_app_config;

#lazy loading $_app_config
sub app_config {
    $_app_config = BOM::Config::Runtime->instance->app_config() unless $_app_config;
    return $_app_config;
}

=head2 transfer_between_accounts_limits

Transfer limits are returned as a {currency => {min => 1, max => 2500}, ... } hash ref.
These values are extracted from app_config->payment.transfer_between_accounts.minimum/maximum editable in backoffice Dynamic Settings page.

=over4

=item * if true, transfer between accouts will be recalculated (a little expensive); otherwise, use the cached values.

=back

=cut

sub transfer_between_accounts_limits {
    my ($force_refresh) = @_;

    state $currency_limits_cache = {};
    my $current_revision = BOM::Config::Runtime->instance->app_config()->current_revision // '';
    return $currency_limits_cache
        if (not $force_refresh)
        and $currency_limits_cache->{revision}
        and ($currency_limits_cache->{revision} eq $current_revision);

    my $lower_bounds = transfer_between_accounts_lower_bounds();

    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $configs = app_config()->get([
        'payments.transfer_between_accounts.minimum.default.fiat', 'payments.transfer_between_accounts.minimum.default.crypto',
        'payments.transfer_between_accounts.minimum.by_currency',  'payments.transfer_between_accounts.maximum.default'
    ]);

    my $configs_json = JSON::MaybeUTF8::decode_json_utf8($configs->{'payments.transfer_between_accounts.minimum.by_currency'});

    my $currency_limits = {};
    foreach my $currency (@all_currencies) {
        my $type = LandingCompany::Registry::get_currency_type($currency);
        $type = 'fiat' if (LandingCompany::Registry::get_currency_definition($currency)->{stable});

        my $min = $configs_json->{$currency} // $configs->{"payments.transfer_between_accounts.minimum.default.$type"};
        my $lower_bound = $lower_bounds->{$currency};

        if ($min < $lower_bound) {
            $log->tracef("The %s transfer minimum of %d in app_config->payements.transfer_between_accounts.minimum was too low. Raised to %d",
                $currency, $min, $lower_bound);
            $min = $lower_bound;
        }

        my $max = try {
            return 0 +
                financialrounding('amount', $currency,
                convert_currency($configs->{'payments.transfer_between_accounts.maximum.default'}, 'USD', $currency));
        }
        catch { return undef; };

        $currency_limits->{$currency}->{min} = 0 + financialrounding('amount', $currency, $min);
        $currency_limits->{$currency}->{'max'} = $max if $max;
    }

    $currency_limits->{revision} = $current_revision;
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
    my $current_revision = BOM::Config::Runtime->instance->app_config()->current_revision // '';
    return $transfer_fees_cache if $transfer_fees_cache->{revision} and ($transfer_fees_cache->{revision} eq $current_revision);

    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $configs = app_config()->get([
        'payments.transfer_between_accounts.fees.default.fiat_fiat',   'payments.transfer_between_accounts.fees.default.fiat_crypto',
        'payments.transfer_between_accounts.fees.default.fiat_stable', 'payments.transfer_between_accounts.fees.default.crypto_fiat',
        'payments.transfer_between_accounts.fees.default.stable_fiat', 'payments.transfer_between_accounts.fees.by_currency'
    ]);
    my $fee_by_currency = JSON::MaybeUTF8::decode_json_utf8($configs->{'payments.transfer_between_accounts.fees.by_currency'});

    my $currency_config;
    for my $from_currency (@all_currencies) {
        my $from_def = LandingCompany::Registry::get_currency_definition($from_currency);
        my $from_category = $from_def->{stable} ? 'stable' : $from_def->{type};

        my $fees;
        foreach my $to_currency (@all_currencies) {
            my $to_def = LandingCompany::Registry::get_currency_definition($to_currency);

            #Same-currency and crypto-to-crypto transfers are not supported: fee = undef.
            unless (($from_def->{type} eq 'crypto' and $to_def->{type} eq 'crypto') or $from_currency eq $to_currency) {
                my $to_category = $to_def->{stable} ? 'stable' : $to_def->{type};
                my $fee = $fee_by_currency->{"${from_currency}_$to_currency"}
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

    $currency_config->{revision} = $current_revision;
    $transfer_fees_cache = $currency_config;
    return $currency_config;
}

=head2 transfer_between_accounts_lower_bounds

Calculates the minimum amount acceptable for all available currencies. 
It should be guaranteed that tranfering any amount higher than the lower bound
will not lead to depositing an amount less than the minimum unit for any receiving currency. 
Reversing the calculations of BOM_Platform_Client_CashierValidation::calculate_to_amount_with_fees 
it computes the amount of a source currency that would deposit at least a minmum unit of any receiving currency,
considering the exchange rates and transfer fees (the maximum of which is %7) involved.
It doesn't have any input arg and returns:

=over4

=item * A hash-ref containing the lower bounds of currencies, like: {USD => 0.03, EUR => 0.02, ... }

=back

=cut

sub transfer_between_accounts_lower_bounds {
    my @all_currencies = sort(LandingCompany::Registry::all_currencies());
    my $result         = {};
    for my $target_currency (@all_currencies) {
        $result->{$target_currency} = 0;
        for my $to_currency (@all_currencies) {
            try {
                my $amount = get_min_unit($to_currency);
                $amount = convert_currency($amount, $to_currency, $target_currency) unless $target_currency eq $to_currency;
                $amount = max($amount * 100 / (100 - MAX_TRANSFER_FEE), $amount + get_min_unit($target_currency));
                $result->{$target_currency} = $amount if $result->{$target_currency} < $amount;
            }
            catch {
                $log->tracef("No exchange rate for the currency pair %s-%s.", $target_currency, $to_currency);
            };
        }

        my $rounded = financialrounding('amount', $target_currency, $result->{$target_currency});
        my $min_unit = get_min_unit($target_currency);
        # increase by min_unit is if the value is truncated by financial rounding
        $rounded = financialrounding('amount', $target_currency, $rounded + $min_unit) if $result->{$target_currency} - $rounded > $min_unit / 10.0;
        $result->{$target_currency} = $rounded;
    }

    return $result;
}

=head2 rate_expiry

Gets exchange rates quote expiry time for a currency pair.
For fiat currencies, if the FOREX exchange is currently closed, the "fiat_holidays"
app config setting will be used. Otherwise "fiat" is used.
"crypto" is used for crypto currencies.
In the case of different currency types, the shortest expiry time is returned.

=item * The source currrency we want to convert from.

=item * The target currency we want to convert to.

Retruns

=item * The allowed age for exchange rate quote in seconds.

=cut

sub rate_expiry {
    my @types = map { LandingCompany::Registry::get_currency_type($_) } @_;
    my %config = map { $_ => app_config()->get('payments.transfer_between_accounts.exchange_rate_expiry.' . $_) } qw( fiat fiat_holidays crypto );

    my $reader   = BOM::Config::Chronicle::get_chronicle_reader;
    my $calendar = Quant::Framework->new->trading_calendar($reader);
    my $exchange = Finance::Exchange->create_exchange('FOREX');
    my $fiat_key = $calendar->is_open($exchange) ? 'fiat' : 'fiat_holidays';

    my @expiries = map { $config{$_ eq 'fiat' ? $fiat_key : $_} } @types;
    return min(@expiries);
}

1;
