package BOM::Product::Utils;

use strict;
use warnings;

use BOM::Config::Chronicle;
use Exporter qw(import);
use Finance::Underlying;
use Finance::Exchange;
use Format::Util::Numbers qw(roundcommon);
use POSIX                 qw(ceil floor);
use Quant::Framework;

our @EXPORT_OK = qw( business_days_between weeks_between beautify_stake roundup rounddown );

=head1 NAME

BOM::Product::Utils - useful methods that can be shared across different contract types

=cut

=head2 CURRENCY_PRECISION_FACTOR

A factor used to reduce the currency precision.
This is to avoid the display for C<min_stake> and C<max_stake> flickering every second especially for cryptocurrencies.

=cut

use constant CURRENCY_PRECISION_FACTOR => 0.8;

=head2 roundup

round up a value
roundup(63800, 1000) = 64000

=cut

sub roundup {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    my $rounded_value = ceil($value_to_round / $precision) * $precision;

    return roundcommon($precision, $rounded_value);
}

=head2 rounddown

round down a value
roundown(63800, 1000) = 63000

=cut

sub rounddown {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    my $rounded_value = floor($value_to_round / $precision) * $precision;

    return roundcommon($precision, $rounded_value);
}

=head2 beautify_stake($stake_amount, $currency, $is_min_stake)

Beautifies the C<$stake_amount> based on the given C<$currency> and C<$is_min_stake> flag.

=head3 Parameters

=over 4

=item C<$stake_amount> - number

The original stake amount.

=item C<$currency> - string

The currency for which the precision is determined.

=item C<$is_min_stake> - boolean

A flag indicating whether the stake amount is min_stake or max_stake
1 - min_stake
0 or undef - max_stake

=back

=head3 Returns

Returns the beautified C<$stake_amount>. For example:
beautify_stake(15.19, 'USD', 1) = 16.00              # min_stake
beautify_stake(15.19, 'USD') = 15.00                 # max_stake
beautify_stake(0.04322406, 'BTC', 1) = 0.04322400    # min_stake
beautify_stake(0.04322406, 'BTC') = 0.04322500       # max_stake

=head3 Description

If the stake amount is greater than 1, it rounds up to the nearest integer for min_stake
and rounds down to the nearest integer for max_stake.
Otherwise, it uses the C<roundup> or C<rounddown> function with the reduced currency precision to round the stake amount.

=cut

sub beautify_stake {
    my ($stake_amount, $currency, $is_min_stake) = @_;

    my $currency_precision = Format::Util::Numbers::get_precision_config()->{price}->{$currency};

    if ($stake_amount >= 1) {
        $stake_amount = $is_min_stake ? ceil($stake_amount) : floor($stake_amount);
    } else {
        my $reduced_precision = floor($currency_precision * CURRENCY_PRECISION_FACTOR);

        $reduced_precision = 10**-$reduced_precision;
        $stake_amount =
            $is_min_stake
            ? roundup($stake_amount, $reduced_precision)
            : rounddown($stake_amount, $reduced_precision);
    }

    $stake_amount = roundcommon(10**-$currency_precision, $stake_amount);

    return $stake_amount;
}

=head2 business_days_between

takes 2 Date::Utility object and 1 Finance::Underlying object, returns how many business days are between the two dates

=cut

sub business_days_between {
    my ($from, $to, $underlying) = @_;

    die '$from must be smaller than $to' if $from->is_after($to);

    my $exchange_name    = $underlying->exchange_name;
    my $exchange         = Finance::Exchange->create_exchange($exchange_name);
    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());

    # +1 because if from and to are just t and t+1, we would want this to be 1
    return $trading_calendar->trading_days_between($exchange, $from, $to) + 1;
}

=head2 weeks_between

Takes 2 Date::Utility object and returns number of weeks between the two dates.
Doesn't consider business days

=cut

sub weeks_between {
    my ($from, $to) = @_;

    die '$from must be smaller than $to' if $from->is_after($to);

    my $days_between  = abs($from->days_between($to));
    my $weeks_between = int($days_between / 7);          #hard coding 7 days a week as this will hardly change

    return $weeks_between;
}

1;
