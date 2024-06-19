package BOM::Config::Quants;

use strict;
use warnings;

=head1 NAME

C<BOM::Config::Quants>

=head1 DESCRIPTION

This module exports methods to get our quants and trading configuration.

=cut

use ExchangeRates::CurrencyConverter qw(convert_currency);
use List::Util                       qw(max);
use Format::Util::Numbers            qw(roundnear);
use BOM::Config::Redis;
use Time::HiRes qw(gettimeofday tv_interval);
use Cache::LRU;

use DataDog::DogStatsd::Helper qw(stats_inc);
use Log::Any                   qw($log);

use Exporter qw(import);
our @EXPORT_OK = qw(get_exchangerates_limit market_pricing_limits minimum_payout_limit maximum_payout_limit minimum_stake_limit maximum_stake_limit);

use constant {
    ERL_CACHE_EXPIRY => 10,
    MAX_DEVIATION    => 0.2,
};

my $exchange_rate_limit_cache = Cache::LRU->new(size => 1000);
sub get_exchange_rate_limit_cache_ref { return $exchange_rate_limit_cache; }

=head2 get_exchangerates_limit

Gets the required exchange rate limit from redis.

Since those limits have a ttl in redis, exchangerates will be updated automatically when the key
exrpires and someone request it.
'exchangerates_update_interval:'' field. Must be in seconds

=over 4

=item C<value> - The value to convert and round

=item C<currency> - The currency of the requested limit

=back

Returns a single number, the limit of the requested currency

=cut

sub get_exchangerates_limit {
    my ($value, $currency) = @_;
    my $unit = 'USD';

    return undef  if (not(defined $value and defined $currency));
    return $value if ($value == 0 or $currency eq $unit);

    my $key = "limit:$unit-to-$currency:$value";
    my $price;
    # Do we have a cache miss?
    if (!$exchange_rate_limit_cache->get($key) || tv_interval($exchange_rate_limit_cache->get($key)->{time}) > ERL_CACHE_EXPIRY) {
        $price = convert_currency($value + 0, $unit, $currency);
        if (defined $price) {
            $price = _round($price, MAX_DEVIATION);
            $exchange_rate_limit_cache->set(
                $key => {
                    time => [gettimeofday],
                    erl  => $price
                });
        }
    } else {
        $price = $exchange_rate_limit_cache->get($key)->{erl};
    }

    return $price;
}

=head2 _round

Function to round the price within the allowed deviance

=over 4

=item C<number> - Any price in any currency

=item C<crypto_symbol> - The allowed deviance, default 0.2

=back

Returns a single number, the new rounded price

=cut

sub _round {
    my ($number, $allowed_difference) = @_;

    return $number if ($number == 0 or (not defined $number));
    my $rounded;

    #if allowed deviance is not provided default is 20%
    $allowed_difference = $allowed_difference // 0.2;
    my $power = 10;
    do {
        $rounded = roundnear(10**$power, $number + 0);
        $power--;
    } until (abs($rounded - $number) / max($rounded, $number) <= $allowed_difference);

    # $rounded should never be undefined. If it is, we should capture it here and reset it to $number.
    unless (defined $rounded) {
        $log->warnf("Fail to round with the following arguments: %s", ($number, $allowed_difference));
        $rounded = $number;
    }

    return $rounded;
}

=head2 market_pricing_limits

Takes the following argument(s):

=over 4

=item * C<$currencies> - An arrayref of currency codes

=item * C<$lc> - The landing company shortcode as a string

=item * C<$markets> - An arrayref of market types

=item * C<$contract_categories> - An arrayref of contract categories

=back

Returns the hashref of market pricing limits for desired market, landing company,
contract category and currency combination.

=cut

sub market_pricing_limits {
    my ($currencies, $lc, $markets, $contract_categories) = @_;

    $lc                  ||= "default_landing_company";
    $markets             ||= ["default_market"];
    $contract_categories ||= ['default_contract_category'];

    my $config = BOM::Config::quants()->{bet_limits};
    my $lc_min = $config->{min_stake}->{$lc}  || $config->{min_stake}->{default_landing_company};
    my $lc_max = $config->{max_payout}->{$lc} || $config->{max_payout}->{default_landing_company};

    my $limits = {};

    for my $market (@$markets) {
        my $market_min = $lc_min->{$market} || $lc_min->{default_market};
        my $market_max = $lc_max->{$market} || $lc_max->{default_market};
        foreach my $contract_category (@$contract_categories) {
            my $cat_min = $market_min->{$contract_category} // $market_min->{default_contract_category};
            my $cat_max = $market_max->{$contract_category} // $market_max->{default_contract_category};

            for my $currency (@$currencies) {
                my $min_stake  = get_exchangerates_limit($cat_min->{$currency}, $currency);
                my $max_payout = get_exchangerates_limit($cat_max->{$currency}, $currency);

                if (not defined $min_stake or not defined $max_payout) {
                    stats_inc('bom_config.quants.market_pricing_limits.unsupported_currency', {tags => ['currency:' . $currency]});
                }

                $limits->{$market}->{$currency}->{max_payout} = $max_payout + 0
                    if defined $max_payout;    #add plus 0 to ensure it will always be a number instead of string
                $limits->{$market}->{$currency}->{min_stake} = $min_stake + 0 if defined $min_stake;
            }
        }
    }

    return $limits;
}

=head2 minimum_payout_limit

Takes the following argument(s):

=over 4

=item * C<$currency> - ISO currency code as a string

=item * C<$lc> - The landing company shortcode as a string

=item * C<$market> - Market type as a string

=item * C<$contract_category> - The contract category as a string

=back

Returns the minimum payout limit for the desired currency, landing company,
market and contract category combination.

=cut

sub minimum_payout_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('min_payout', $currency, $lc, $market, $contract_category);
}

=head2 maximum_payout_limit

Takes the following argument(s):

=over 4

=item * C<$currency> - ISO currency code as a string

=item * C<$lc> - The landing company shortcode as a string

=item * C<$market> - Market type as a string

=item * C<$contract_category> - The contract category as a string

=back

Returns the maximum payout limit for the desired currency, landing company,
market and contract category combination.

=cut

sub maximum_payout_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('max_payout', $currency, $lc, $market, $contract_category);
}

=head2 minimum_stake_limit

Takes the following argument(s):

=over 4

=item * C<$currency> - ISO currency code as a string

=item * C<$lc> - The landing company shortcode as a string

=item * C<$market> - Market type as a string

=item * C<$contract_category> - The contract category as a string

=back

Returns the minimum stake limit for the desired currency, landing company,
market and contract category combination.

=cut

sub minimum_stake_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('min_stake', $currency, $lc, $market, $contract_category);
}

=head2 maximum_stake_limit

Takes the following argument(s):

=over 4

=item * C<$currency> - ISO currency code as a string

=item * C<$lc> - The landing company shortcode as a string

=item * C<$market> - Market type as a string

=item * C<$contract_category> - The contract category as a string

=back

Returns the maximum payout limit for the desired currency, landing company,
market and contract category combination.

=cut

sub maximum_stake_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('max_stake', $currency, $lc, $market, $contract_category);
}

sub _get_amount_limit {
    my ($amount_type, $currency, $lc, $market, $contract_category) = @_;

    my $config    = BOM::Config::quants()->{bet_limits}{$amount_type} // die $amount_type . ' not defined';
    my $by_lc     = (defined $lc     and $config->{$lc})    ? $config->{$lc}    : $config->{'default_landing_company'};
    my $by_market = (defined $market and $by_lc->{$market}) ? $by_lc->{$market} : $by_lc->{'default_market'};
    my $by_cc =
        (defined $contract_category and $by_market->{$contract_category})
        ? $by_market->{$contract_category}
        : $by_market->{'default_contract_category'};

    return get_exchangerates_limit($by_cc->{$currency}, $currency);
}

1;
