package BOM::Platform::CryptoCashier::Config;

=head1 NAME

BOM::Platform::CryptoCashier::Config

=head1 DESCRIPTION

This module contains the helper to get the cryptocurrency config from the crypto cashier

=cut

use strict;
use warnings;

use BOM::Config::CurrencyConfig;
use BOM::Config::Redis;

use ExchangeRates::CurrencyConverter qw/convert_currency/;
use Format::Util::Numbers qw/financialrounding/;
use LandingCompany::Registry;

use constant {
    CRYPTO_CONFIG_REDIS_KEY => "cryptocurrency::crypto_config::",
};

=head2 crypto_config

Get the config of the selected currency otherwise get the config of all enabled crypto currency

=over 4

=item * C<$currency_code> - (optional) the cryptocurrency code

=back

Returns a hash reference contains currencies_config key has a hash reference for each currency for its configs.
The currency config keys:

=over 4

=item * C<minimum_withdrawal> - The currency minimum withdrawal amount

=back

=cut

sub crypto_config {
    my ($currency_code) = @_;

    my $result            = {currencies_config => {}};
    my @crypto_currencies = $currency_code || LandingCompany::Registry::all_crypto_currencies();
    @crypto_currencies = grep { !BOM::Config::CurrencyConfig::is_crypto_currency_suspended($_) } @crypto_currencies;

    return $result unless @crypto_currencies;

    # Retrieve from redis
    my $redis_read     = BOM::Config::Redis::redis_replicated_read();
    my $crypto_configs = $redis_read->mget(map { CRYPTO_CONFIG_REDIS_KEY . $_ } @crypto_currencies);

    #it might be possible that for some currencies crypto config stored in redis is expired, below is handling of that
    #$crypto_configs have values in same order of @crypto_currencies array
    for (my $index = 0; $index < @{$crypto_configs}; $index++) {
        my $min_withdrawal = $crypto_configs->[$index] // fixed_crypto_config($crypto_currencies[$index]);
        $result->{currencies_config}{$crypto_currencies[$index]}{minimum_withdrawal} = $min_withdrawal if $min_withdrawal;
    }

    # Return all
    return $result unless $currency_code;

    # Return the requested currency only
    return {
        currencies_config => {
            $currency_code => $result->{currencies_config}{$currency_code} // {},
        },
    };
}

=head2 fixed_crypto_config

Returns crypto config from bom config for passed currency_code

=over 4

=item * C<currency_code> - (required)

=back

=cut

sub fixed_crypto_config {
    my $currency_code = shift;

    return undef unless $currency_code;
    return undef if BOM::Config::CurrencyConfig::is_crypto_currency_suspended($currency_code);

    my $converted = eval { convert_currency(BOM::Config::CurrencyConfig::get_crypto_withdrawal_min_usd($currency_code), 'USD', $currency_code); };

    return 0 + financialrounding('amount', $currency_code, $converted) if $converted;
    return undef;
}

1;
