package BOM::TradingPlatform::DXTrader;

use strict;
use warnings;
no indirect;

=head1 NAME 

BOM::TradingPlatform::DXTrader - The DevExperts trading platform implementation.

=head1 SYNOPSIS 

    my $dx = BOM::TradingPlatform::DXTrader->new();
    $dx->deposit(...);

=head1 DESCRIPTION 

Provides a high level implementation of the DevExperts API.

Exposes DevExperts API through our trading platform interface.

This module must provide support to each DevExperts integration within our systems.

=cut

use parent qw(BOM::TradingPlatform);

=head2 new

Creates and returns a new L<BOM::TradingPlatform::DXTrader> instance.

=cut

sub new {
    return bless {}, 'BOM::TradingPlatform::DXTrader';
}

=head2 new_account

The DXTrader implementation of account creation.

=cut

sub new_account {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 change_password

The DXTrader implementation of changing password.

=cut

sub change_password {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 check_password

The DXTrader implementation of checking password.

=cut

sub check_password {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 reset_password

The DXTrader implementation of resetting password.

=cut

sub reset_password {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 deposit

The DXTrader implementation of making a deposit.

=cut

sub deposit {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 withdraw

The DXTrader implementation of making a withdrawal.

=cut

sub withdraw {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 get_accounts

The DXTrader implementation of getting accounts list.

=cut

sub get_accounts {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 get_account_info

The DXTrader implementation of getting an account info.

=cut

sub get_account_info {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 get_open_positions

The DXTrader implementation of getting an account open positions

=cut

sub get_open_positions {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

1;
