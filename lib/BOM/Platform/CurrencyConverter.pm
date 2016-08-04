package BOM::Platform::CurrencyConverter;

use strict;
use warnings;
use Cache::RedisDB;
use Scalar::Util ('looks_like_number');
use Exporter qw/import/;
our @EXPORT_OK = qw(in_USD amount_from_to_currency);

sub in_USD {
    my $price         = shift;
    my $from_currency = shift;

    die "No valid amount or source currency was provided"
        unless looks_like_number $price and defined $from_currency;

    return $price if $price == 0 or $from_currency eq 'USD';

    my $spot = Cache::RedisDB->get('QUOTE', "frx${from_currency}USD");
    return $price * $spot->{quote} if $spot and looks_like_number $spot->{quote};

    # look for invert currency pair
    $spot = Cache::RedisDB->get('QUOTE', "frxUSD${from_currency}");
    if ($spot and looks_like_number $spot->{quote}) {
        return $price / $spot->{quote};
    }

    die "No spot to convert for [frx${from_currency}USD, frxUSD${from_currency}].";
}

sub amount_from_to_currency {
    my ($amt, $currency, $tocurrency) = @_;

    return $amt if $amt == 0 or $currency eq $tocurrency;
    return in_USD($amt, $currency) / in_USD(1, $tocurrency);
}

1;
