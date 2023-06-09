package BOM::Product::Utils;

use strict;
use warnings;

use Finance::Underlying;
use Finance::Exchange;
use Quant::Framework;
use BOM::Config::Chronicle;
use POSIX qw(ceil floor);

use Exporter 'import';

our @EXPORT_OK = qw( business_days_between weeks_between roundup rounddown );

=head1 NAME

BOM::Product::Utils - useful methods that can be shared across different contract types

=cut

=head2 roundup

round up a value
roundup(63800, 1000) = 64000

=cut

sub roundup {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    return ceil($value_to_round / $precision) * $precision;
}

=head2 rounddown

round down a value
roundown(63800, 1000) = 63000

=cut

sub rounddown {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    return floor($value_to_round / $precision) * $precision;
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
