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

=head2 linked_accounts

Returns a L<BOM::User::Wallet> account details with a list of linked Trading account details:

    {
        wallet => {
            linked_to => [
                {
                    account_id => 'CR1000',
                    balance    => '0.00',
                    currency   => 'USD',
                    platform   => 'binary'
                },
                {
                    account_id => 'MTR1000',
                    balance    => '0.00',
                    currency   => 'USD'
                    platform   => 'mt5'
                },
                {
                    account_id => 'DXR1000'
                    balance    => '0.00',
                    currency   => 'USD',
                    platform   => 'dxtrade'
                }
            ],
            account_id     => 'DW1000',
            payment_method => 'Skrill',
            balance        => '0.00',
            currency       => 'USD'
        }
    }

=cut

sub linked_accounts {
    my $self = shift;

    my $linked_wallet = $self->user->linked_wallet($self->loginid);

    my @linked_to;
    for (@{$linked_wallet}) {
        my $details = $self->user->get_account_by_loginid($_->{loginid});

        push @linked_to,
            {
            account_id => $details->{account_id},
            balance    => $details->{display_balance},
            currency   => $details->{currency},
            platform   => $details->{platform}};
    }

    return {
        wallet => {
            linked_to      => \@linked_to,
            account_id     => $self->loginid,
            balance        => formatnumber('amount', $self->currency, $self->default_account->balance),
            currency       => $self->currency,
            payment_method => $self->payment_method,
        }};
}

1;

