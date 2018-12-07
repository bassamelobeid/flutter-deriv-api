package BOM::Config::CurrencyConfig;

=head1 NAME

BOM::Config::CurrencyConfig

=head1 DESCRIPTION

A repository of dynamic configurations set on currencies, like their minimum/maximum limits.

=cut

use strict;
use warnings;
use feature 'state';

use JSON::MaybeUTF8;

use Format::Util::Numbers;
use LandingCompany::Registry;
use BOM::Config::Runtime;

my $_app_config;

#lazy loading $_app_config
sub app_config {
    $_app_config = BOM::Config::Runtime->instance->app_config() unless $_app_config;
    return $_app_config;
}

=head2 transfer_between_accounts_limits

Transfer limits are returned as a {currency => {min => 1}, ... } hash ref (there aren't any predefined maximum limits for now).
These values are extracted from app_config->payment.transfer_between_accounts.minimum, editable in backoffice Dynamic Settings page.
=cut

sub transfer_between_accounts_limits {
    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $configs = app_config()->get([
        'payments.transfer_between_accounts.minimum.default.fiat', 'payments.transfer_between_accounts.minimum.default.crypto',
        'payments.transfer_between_accounts.minimum.by_currency'
    ]);
    my $configs_json = JSON::MaybeUTF8::decode_json_utf8($configs->{'payments.transfer_between_accounts.minimum.by_currency'});

    my %currency_limits = map {
        my $type = LandingCompany::Registry::get_currency_type($_);
        my $min = $configs_json->{$_} // $configs->{"payments.transfer_between_accounts.minimum.default.$type"};
        $_ => {
            min => 0 + Format::Util::Numbers::financialrounding('price', $_, $min),
            }
    } @all_currencies;

    return \%currency_limits;
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
                $fees->{$to_currency} = 0 + Format::Util::Numbers::roundcommon(0.01, $fee);
            }
        }

        $currency_config->{$from_currency} = $fees;
    }

    $currency_config->{revision} = $current_revision;
    $transfer_fees_cache = $currency_config;
    return $currency_config;
}

1;
