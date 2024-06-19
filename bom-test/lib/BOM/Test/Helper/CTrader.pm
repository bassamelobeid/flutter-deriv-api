package BOM::Test::Helper::CTrader;

use strict;
use warnings;

use BOM::MT5::User::Async;
use Test::MockModule;

my $mock_ctrader;
my $loginid  = 100001;
my $ctid     = 1001;
my $traderid = 1;
my %accounts;
my %traderid_loginid;
my %email_ctid;

my %methods = (
    trader_create => sub {
        my $args = shift;
        my $acc  = {
            login                 => $loginid,
            groupName             => 'ctrader_all_svg_std_usd',
            registrationTimestamp => time(),
            depositCurrency       => 'USD',
            balance               => 0,
            moneyDigits           => 2,
        };
        $accounts{$loginid} = $acc;
        $traderid_loginid{$traderid++} = $loginid;
        $loginid++;
        return $acc;
    },
    trader_get => sub {
        my $args = shift;
        return $accounts{$args->{loginid}};
    },
    ctid_create => sub {
        my $args = shift;
        $email_ctid{$args->{email}} = $ctid++;
        return {
            userId => $email_ctid{$args->{email}},
        };
    },
    ctid_getuserid => sub {
        my $args = shift;
        return {
            userId => $email_ctid{$args->{email}},
        };
    },
    ctid_linktrader => sub {
        my $args = shift;
        return {
            ctidTraderAccountId => $args->{traderLogin},
        };
    },
    ctradermanager_getgrouplist => sub {
        return [{
                name    => 'ctrader_all_svg_std_usd',
                groupId => 1,
            }];
    },
    tradermanager_gettraderlightlist => sub {
        my $args = shift;
        return [map { {login => $traderid_loginid{$_}, traderId => $_,} } keys %traderid_loginid];
    },
    tradermanager_deposit => sub {
        my $args  = shift;
        my $login = $traderid_loginid{$args->{traderId}} or return;
        $accounts{$login}->{balance} += $args->{amount};
        return {balanceHistoryId => 1};
    },
    tradermanager_withdraw => sub {
        my $args  = shift;
        my $login = $traderid_loginid{$args->{traderId}} or return;
        $accounts{$login}->{balance} -= $args->{amount};
        return {balanceHistoryId => 1};
    },
);

sub mock_server {
    $mock_ctrader = Test::MockModule->new('BOM::TradingPlatform::CTrader');

    $mock_ctrader->mock(
        call_api => sub {
            my (undef, %args) = @_;
            my $method = $args{method};
            warn "unmocked CTrader method $method" unless $methods{$method};
            $methods{$method}->($args{payload});
        });
}

1;
