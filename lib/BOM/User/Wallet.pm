package BOM::User::Wallet;

use strict;
use warnings;
use LandingCompany::Wallet;
use LandingCompany::Registry;

use parent 'BOM::User::Client';

=head2 new

Uses same arguments as BOM::User::Client.

Example usage:

    BOM::User::Wallet->new({loginid => 'DW0001'});

=cut

sub new {
    my $self = shift->SUPER::new(@_) // return;
    $self->{config} = LandingCompany::Wallet::get_wallet_for_broker($self->broker_code)
        // die 'Broker code ' . $self->broker_code . ' is not a wallet';
    return $self;
}

=head2 config

Returns the wallet config.

=cut

sub config { return shift->{config} }

=head2 landing_company

Returns the landing company config.

=cut

sub landing_company {
    my $self = shift;

    return LandingCompany::Registry::get($self->config->{landing_company});
}

=head2 is_wallet

Returns whether this client instance is a wallet.

=cut

sub is_wallet { 1 }

=head2 can_trade

Returns whether this client instance can perform trading.

=cut

sub can_trade { 0 }

1;
