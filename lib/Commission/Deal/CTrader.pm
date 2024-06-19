package Commission::Deal::CTrader;

use strict;
use warnings;
use Commission::Helper::CTraderHelper;

=head1 NAME

Commission::Deal::CTrader - Place holder class for an order from cTrader platform

=head1 SYNOPSIS

 use Commission::Deal::CTrader;
 my $ct_deal = Commission::Deal::CTrader->new(
    traderId => '123',
    filledVolume => 100000,
    executionPrice => 1.05279,
    executionTimestamp => '2023-10-05T03:46:39.560Z',
    dealId => '123',
    server => 'demo',
 );

 $ct_deal->volume;
 $ct_deal->underlying_symbol;

=cut

=head2 new

Create a new instance.

=cut

sub new {
    my ($class, %args) = @_;

    $args{ctrader_helper} = Commission::Helper::CTraderHelper->new(
        redis  => $args{redis},
        server => $args{server});

    return bless \%args, $class;
}

=head2 volume

number of lots * contract size

=cut

sub volume { abs(shift->{filledVolume}) }

=head2 spread

The difference between bid & ask price of the underlying symbol

=cut

sub spread { shift->{spread} // 0 }

=head2 underlying_symbol

The asset

=cut

sub underlying_symbol {
    my $self = shift;

    my $symbol = $self->{ctrader_helper}->get_underlying_symbol(dealId => $self->{dealId});

    return $symbol;
}

=head2 underlying_symbol_id

The id of the asset

=cut

sub underlying_symbol_id {
    my $self = shift;

    my $symbol_id = $self->{ctrader_helper}->get_symbolid_by_dealid(dealId => $self->{dealId});

    return $symbol_id;
}

=head2 loginid

The client loginid of CTrader

=cut

sub loginid {
    my $self = shift;

    my $loginid = $self->{ctrader_helper}->get_loginid(traderIds => $self->{traderId});

    return $loginid;
}

=head2 deal_id

The unique identifier of deal on CTrader. dealId is the deal id instead of orderCode. 

=cut

sub deal_id { shift->{dealId} }

=head2 transaction_time

The execution time of the deal

=cut

sub transaction_time { shift->{executionTimestamp} }

=head2 price

The price of the asset

=cut

sub price { shift->{executionPrice} }

=head2 account_type

Account type on CTrader. It could be high risk etc.

Currently, it is hard-coded to 'standard'

=cut

sub account_type { return 'standard' }

=head2 is_valid

Is deal filled and valid to be processed

=cut

sub is_valid { shift->{status} eq '"FILLED"' ? 1 : 0 }

=head2 is_test_account

Is this deal performed with a test account

=cut

sub is_test_account {
    return shift->loginid !~ /^CTR\d+$/ ? 1 : 0;
}

1;
