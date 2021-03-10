package BOM::TradingPlatform;

use strict;
use warnings;
no indirect;

=head1 NAME 

BOM::TradingPlatform - Trading platform interface.

=head1 SYNOPSIS 

    my $dxtrader = BOM::TradingPlatform->new(platform => 'DXtrade', client => $client);
    $dxtrader->deposit(...);

    my $mt5 = BOM::TradingPlatform->new(platform =>'mt5', client => $client);
    $dxtrader->deposit(...);

=head1 DESCRIPTION 

This module provide a layer of abstraction to our trading platforms.

Denotes the interface our trading platforms must implement to operate and integrate with
the rest of our system.

=cut

use BOM::TradingPlatform::DXTrader;
use BOM::TradingPlatform::MT5;

use constant CLASS_DICT => {
    mt5     => 'BOM::TradingPlatform::MT5',
    dxtrade => 'BOM::TradingPlatform::DXTrader',
};
use constant INTERFACE => qw(
    new_account
    change_password
    deposit
    withdraw
    get_account_info
    get_accounts
    get_open_positions
);

for my $method (INTERFACE) {
    no strict "refs";
    *{"BOM::TradingPlatform::$method"} = sub {
        my ($self) = @_;
        die sprintf '%s not yet implemented by %s', $method, ref($self);
    }
}

=head2 new

Creates a new valid L<BOM::TradingPlatform> instance.

It takes the following parameters:

=over 4

=item * C<platform> The name of the trading platform being instantiated.

=back

We curently support as valid trading platform names:

=over 4

=item * C<mt5> The MT5 trading platform.

=item * C<dxtrader> The DevExperts trading platform.

=back

Returns a valid implementation of L<BOM::TradingPlatform>

=cut

sub new {
    my (undef, %args) = @_;

    my $class = CLASS_DICT->{$args{platform}}
        or die "Unknown trading platform: $args{platform}";

    return bless {client => $args{client}}, $class;
}

=head2 client

Returns client instance provided to new().

=cut

sub client { return shift->{client} }

1;
