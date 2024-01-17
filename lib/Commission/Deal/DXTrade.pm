package Commission::Deal::DXTrade;

use strict;
use warnings;

=head1 NAME

Commission::Deal::DXTrade - Place holder class for an order from DerivX platform

=head1 SYNOPSIS

 use Commission::Deal::DXTrade;
 my $dx_deal = Commission::Deal::DXTrade->new(
    account => 'default:DXD123',
    positionCode => 123,
    symbol => 'EURUSD',
    spread => 0.001,
    quantity => 100000,
    openTime => '2021-06-10 20:00:05',
    openPrice => 1.234
 );

 $dx_deal->volume;
 $dx_deal->underlying_symbol;

=cut

=head2 new

Create a new instance.

=cut

sub new {
    my ($class, %args) = @_;

    return bless \%args, $class;
}

=head2 volume

number of lots * contract size

=cut

sub volume { abs(shift->{filledQuantity}) }

=head2 spread

The difference between bid & ask price of the underlying symbol

=cut

sub spread { shift->{spread} // 0 }

=head2 underlying_symbol

The asset

=cut

sub underlying_symbol { shift->{instrument} }

=head2 loginid

The client loginid of DXTrade

=cut

sub loginid {
    my $self = shift;
    my (undef, $loginid) = split ':', $self->{account};
    return $loginid;
}

=head2 deal_id

The unique identifier of deal on DXTrade. actionCode is the deal id instead of orderCode. 

=cut

sub deal_id { shift->{actionCode} }

=head2 transaction_time

The execution time of the deal

=cut

sub transaction_time { shift->{transactionTime} }

=head2 price

The price of the asset

=cut

sub price { shift->{lastPrice} }

=head2 account_type

Account type on DXTrade. It could be high risk etc.

Currently, it is hard-coded to 'standard'

=cut

sub account_type { return 'standard' }

=head2 is_valid

Is deal filled and valid to be processed

=cut

sub is_valid { shift->{status} eq 'COMPLETED' ? 1 : 0 }

=head2 is_test_account

Is this deal performed with a test account

=cut

sub is_test_account {
    return shift->loginid !~ /^DXR\d+$/ ? 1 : 0;
}

1;
