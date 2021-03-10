package BOM::TradingPlatform::MT5;

use strict;
use warnings;
no indirect;

=head1 NAME 

BOM::TradingPlatform::MT5 - The MetaTrader5 trading platform implementation.

=head1 SYNOPSIS 

    my $mt5 = BOM::TradingPlatform::MT5->new(client => $client);
    my $account = $mt5->new_account(...)
    $mt5->deposit(account => $account, ...);

=head1 DESCRIPTION 

Provides a high level implementation of the MetaTrader5 API.

Exposes MetaTrader5 API through our trading platform interface.

This module must provide support to each MetaTrader5 integration within our systems.

=cut

use parent qw( BOM::TradingPlatform );

=head2 new

Creates and returns a new L<BOM::TradingPlatform::MT5> instance.

=cut

sub new {
    return bless {}, 'BOM::TradingPlatform::MT5';
}

1;
