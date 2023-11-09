package BOM::Test::Helper::MT5;

use strict;
use warnings;

use BOM::MT5::User::Async;
use Test::MockModule;
use Locale::Country::Extra;

my $mock_mt5;
my $account_id = 1000;
my %accounts;

sub mock_server {
    $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');

    $mock_mt5->mock('get_user', sub { my $login = shift; return Future->done($accounts{$login}) });

    $mock_mt5->mock(
        'create_user',
        sub {
            my $args = shift;

            my $login = $args->{group} =~ /_ez/ ? 'EZ' : 'MT';
            $login .= $args->{group} =~ /^demo/ ? 'D' : 'R';
            $login .= $account_id++;

            $accounts{$login} = +{
                %$args,
                login   => $login,
                balance => 0,
                country => Locale::Country::Extra->new->country_from_code($args->{country} // 'za'),
            };
            return Future->done({login => $login});
        });

    $mock_mt5->mock(
        'deposit',
        sub {
            my $args = shift;

            if (my $acc = $accounts{$args->{login}}) {
                $acc->{balance} += $args->{amount};
            }

            return Future->done({status => 1});
        });

    $mock_mt5->mock(
        'withdrawal',
        sub {
            my $args = shift;

            if (my $acc = $accounts{$args->{login}}) {
                $acc->{balance} += $args->{amount};
            }

            return Future->done({status => 1});
        });

    $mock_mt5->mock(
        'get_group',
        sub {
            return Future->done(
                +{
                    'currency' => 'USD',
                    'group'    => $_[0],
                    'leverage' => 1,
                    'company'  => 'Deriv Limited'
                });
        });
}

1;
