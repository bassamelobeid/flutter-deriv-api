package BOM::User::Wallet;

use strict;
use warnings;

use Format::Util::Numbers qw/formatnumber/;
use List::Util            qw(all);

use parent 'BOM::User::Client';

=head2 new

Uses same arguments as BOM::User::Client.

Example usage:

    BOM::User::Wallet->new({loginid => 'DW0001'});

=cut

sub new {
    my $self = shift->SUPER::new(@_) // return;

    die 'Broker code ' . $self->broker_code . ' is not a wallet'
        unless BOM::User::Client->get_class_by_broker_code($self->broker_code // '') eq 'BOM::User::Wallet';

    return $self;
}

=head2 is_virtual

Returns whether this client instance is a virtual account.

=cut

sub is_virtual {
    my $self = shift;

    return $self->get_account_type->name eq 'virtual' ? 1 : 0;
}

=head2 is_wallet

Returns whether this client instance is a wallet.

=cut

sub is_wallet { 1 }

=head2 is_affiliate

Returns whether this client instance is an affiliate.

=cut

sub is_affiliate { 0 }

=head2 can_trade

Returns whether this client instance can perform trading.

=cut

sub can_trade { 0 }

1;
