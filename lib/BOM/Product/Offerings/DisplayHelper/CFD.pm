package BOM::Product::Offerings::DisplayHelper::CFD;

use Moose;
use namespace::autoclean;
use Finance::Underlying::Market::Registry;
use Finance::Underlying::SubMarket::Registry;
use BOM::Config::Runtime;
extends 'BOM::Product::Offerings::DisplayHelper';

use List::MoreUtils qw(uniq);

=head1 DESCRIPTION

We assume that everything (especially synthetic indices) on Finance::Underlying is offered on CFD platform.

=cut

=head2 get_submarkets

Get all submarkets for a given market in Finance::Underlying.

=cut

sub get_submarkets {
    my ($self, $market) = @_;

    return map { $_->{name} } Finance::Underlying::SubMarket::Registry->find_by_market($market->name);
}

=head2 get_symbols_for_submarket

Get symbols for a given submarket and market in Finance::Underlying.
Excludes suspend_buy symbols

=cut

sub get_symbols_for_submarket {
    my ($self, $market, $submarket) = @_;

    my %suspended_offerings     = map { $_ => 1 } BOM::Config::Runtime->instance->get_offerings_config->{suspend_underlying_symbols}->@*;
    my @offerings_for_submarket = map { $_->{symbol} } grep { $_->{submarket} eq $submarket->name } Finance::Underlying->all_underlyings();

    return grep { not $suspended_offerings{$_} } @offerings_for_submarket;

}

__PACKAGE__->meta->make_immutable;

1;
