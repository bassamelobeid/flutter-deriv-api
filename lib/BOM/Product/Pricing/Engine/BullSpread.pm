package BOM::Product::Pricing::Engine::BullSpread;

use strict;
use warnings;

use Moo;

use Math::Business::BlackScholes::NonBinaries;

=head1 NAME

BOM::Product::Pricing::Engine::BullSpread - The pricing engine for bull spread options.

=cut

=head1 SYNOPSIS


    use BOM::Product::Pricing::Engine::Lookback;

    my $theo_price = BOM::Product::Pricing::Engine::Lookback->new({
                strikes         => 101.5,
                spot            => 100,
                discount_rate   => 0.4,
                t               => 0.1,
                mu              => 0.3,
                vol             => 0.1,
                contract_type   => 'CALLSPREAD',
            })->theo_price;

=cut

my @required_args = qw(spot strikes discount_rate t mu vols contract_type);

=head1 ATTRIBUTES

=head2 contract_type

The contract that we wish to price.

=head2 spot

The spot value of the underlying instrument.

=head2 strikes

The strike{s) of the contract. (Array Reference)

=head2 discount_rate

The interest rate of the payout currency

=head2 mu

The drift of the underlying instrument.

=head2 vol

volatility of the underlying instrument.

=head2 t

Time to expiry

=cut

has [@required_args] => (
    is       => 'ro',
    required => 1,
);

=head2 required_args

Required arguments for this engine to work.

=cut

sub required_args {
    return \@required_args;
}

=head2 theo_price

The theorectical price of this contract.

=cut

sub theo_price {
    my $self = shift;

    my $formula = Math::Business::BlackScholes::NonBinaries->can(lc $self->contract_type) or die 'Cannot price ' . $self->contract_type;

    return $formula->(map { $self->$_ } @required_args);
}
1;
