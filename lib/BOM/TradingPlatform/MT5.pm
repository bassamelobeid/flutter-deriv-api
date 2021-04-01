package BOM::TradingPlatform::MT5;

use strict;
use warnings;
no indirect;

use List::Util qw(first);

use BOM::MT5::User::Async;
use BOM::User::Utility;

use Format::Util::Numbers qw(financialrounding formatnumber);

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
    my ($class, %args) = @_;
    return bless {client => $args{client}}, $class;
}

=head2 get_account_info

The MT5 implementation of getting an account info by loginid.

=over 4

=item * C<$loginid> - an MT5 loginid

=back

Returns a Future object holding an MT5 account info on success, throws exception on error

=cut

sub get_account_info {
    my ($self, $loginid) = @_;

    my @mt5_logins = $self->client->user->mt5_logins;
    my $mt5_login  = first { $_ eq $loginid } @mt5_logins;

    die "InvalidMT5Account\n" unless ($mt5_login);

    my $mt5_user  = BOM::MT5::User::Async::get_user($mt5_login)->get;
    my $mt5_group = BOM::User::Utility::parse_mt5_group($mt5_user->{group});
    my $currency  = uc($mt5_group->{currency});

    return Future->done({
        account_id            => $mt5_user->{login},
        account_type          => $mt5_group->{account_type},
        balance               => financialrounding('amount', $currency, $mt5_user->{balance}),
        currency              => $currency,
        display_balance       => formatnumber('amount', $currency, $mt5_user->{balance}),
        platform              => 'mt5',
        market_type           => $mt5_group->{market_type},
        landing_company_short => $mt5_group->{landing_company_short},
        sub_account_type      => $mt5_group->{sub_account_type},
    });
}

1;
