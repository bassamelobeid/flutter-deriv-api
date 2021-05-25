package BOM::TradingPlatform::MT5;

use strict;
use warnings;
no indirect;

use List::Util qw(first);

use Syntax::Keyword::Try;

use BOM::Config::MT5;
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

use constant {
    MT5_REGEX => qr/^MT[DR]?(?=\d+$)/,
};

=head2 new

Creates and returns a new L<BOM::TradingPlatform::MT5> instance.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {client => $args{client}}, $class;
}

=head2 change_password

Changes the password of MT5 accounts.

Takes the following arguments as named parameters:

=over 4

=item * C<password> (required). the new password.

=back

Returns list of logins on success, throws exception on error

=cut

sub change_password {
    my ($self, %args) = @_;

    my @mt5_loginids = sort $self->client->user->get_mt5_loginids;
    die +{error_code => 'PlatformPasswordChangeSuspended'} if ($self->is_any_mt5_servers_suspended and @mt5_loginids);

    my $password = $args{password} or die 'no password provided';

    # get users
    my @mt5_users = map {
        my $login = $_;
        BOM::MT5::User::Async::get_user($login)->then(
            sub {
                Future->done({login => $login});
            }
        )->catch(
            sub {
                my $error = shift;
                if (($error->{code} // '') eq 'NotFound') {
                    Future->done;
                } else {
                    Future->fail({
                        login => $login,
                        error => $error
                    });
                }
            });
    } @mt5_loginids;

    my @mt5_users_results = Future->wait_all(@mt5_users)->get;

    my ($failed_future, $done_future);
    push @{$_->is_failed ? $failed_future : $done_future}, $_->is_failed ? $_->failure : $_->result for @mt5_users_results;

    return Future->fail(@mt5_users_results) if $failed_future;

    # do password change
    my @mt5_password_change = map {
        my $login = $_->{login};
        BOM::MT5::User::Async::password_change({
                login        => $login,
                new_password => $password,
                type         => 'main'
            })->else(sub { Future->fail({login => $login}) })->then(sub { Future->done({login => $login}) });
    } @{$done_future};

    my @results = Future->wait_all(@mt5_password_change)->get;

    $failed_future = ();
    $done_future   = ();
    push @{$_->is_failed ? $failed_future : $done_future}, $_->is_failed ? $_->failure : $_->result for @results;

    return Future->fail(@results) if $failed_future;
    return Future->done(@$done_future);
}

=head2 change_investor_password

Changes the investor password of an MT5 account.

Takes the following arguments as named parameters:

=over 4

=item * C<$account_id> - an MT5 login

=item * C<new_password> (required). the new password.

=item * C<old_password> (optional). the old password for validation.

=back

Returns a Future object, throws exception on error

=cut

sub change_investor_password {
    my ($self, %args) = @_;

    my $new_password = $args{new_password} or die 'no password provided';
    my $account_id   = $args{account_id}   or die 'no account_id provided';

    my @mt5_loginids = $self->client->user->get_mt5_loginids;
    my $mt5_login    = first { $_ eq $account_id } @mt5_loginids;

    die +{error_code => 'MT5InvalidAccount'} unless $mt5_login;

    my $old_password = $args{old_password};
    if ($old_password) {
        my $error = BOM::MT5::User::Async::password_check({
                login    => $account_id,
                password => $old_password,
                type     => 'investor',
            })->get;
        die $error if $error->{code};
    }

    return BOM::MT5::User::Async::password_change({
        login        => $account_id,
        new_password => $new_password,
        type         => 'investor'
    });
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

=head1 Non-RPC methods

=head2 config

Generates and caches configuration.

=cut

sub config {
    my $self = shift;
    return $self->{config} //= do {
        my $config = BOM::Config::MT5->new;
        $config;
    }
}

=head2 is_any_mt5_servers_suspended

Returns 1 if any of the MT5 servers is currently suspended, returns 0 otherwise

=cut

sub is_any_mt5_servers_suspended {
    my ($self) = @_;

    my $app_config = BOM::Config::Runtime->instance->app_config->system->mt5;

    my $mt5_config = $self->config->webapi_config();
    for my $group_type (qw(demo real)) {
        return 1 if first { $app_config->suspend->all || $app_config->suspend->$group_type->$_->all } sort keys %{$mt5_config->{$group_type}};
    }

    return 0;
}

1;
