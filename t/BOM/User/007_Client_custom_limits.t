#!perl

use strict;
use warnings;

use Test::MockTime;
use Test::MockModule;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;

# create client object
my $client;
Test::Exception::lives_ok { $client = BOM::User::Client::get_instance({'loginid' => 'CR0030'}); }
"Can create client object 'BOM::User::Client::get_instance({'loginid' => CR0030})'";

my $account_balance_limit = $client->get_limit({'for' => 'account_balance'});
is($account_balance_limit, 300000, 'balance limit = 300000');

my $daily_turnover_limit = $client->get_limit({'for' => 'daily_turnover'});
is($daily_turnover_limit, 500000, '50000 by default');

my $payout_limit = $client->get_limit({'for' => 'payout'});
is($payout_limit, 50000, 'open positions payout limit = 50000');

my $open_positions_limit = $client->get_limit({'for' => 'open_positions'});
is($open_positions_limit, 100, 'open positions limit = 100 (constant)');

my $self_exclusion_open_positions_limit = $client->get_limit({'for' => 'open_positions'});
is($self_exclusion_open_positions_limit, 100, 'self exclusion open positions limit not defined, yet. So, default value of 100 is used');

#setting

$client->set_exclusion->max_open_bets(50);

#print Data::Dumper::Dumper($client);

Test::Exception::lives_ok { $client->save(); } 'Can save client';

$client = undef;

#$client = BOM::User::Client::get_instance({'loginid' => 'CR0030'});

Test::Exception::lives_ok { $client = BOM::User::Client->new({'loginid' => 'CR0030'}); } "Force re-pull of client";

{
    my %rates = (
        USD => 1,
        GBP => 1.4,
        EUR => 1.2,
    );
    my $mock = Test::MockModule->new('ExchangeRates::CurrencyConverter');
    $mock->mock(
        in_usd => sub {
            my $price         = shift;
            my $from_currency = shift;

            die "mocked in_usd lacks exchange rate for $from_currency"
                unless exists $rates{$from_currency};

            my $res = $price * $rates{$from_currency};

            note "mocked in_usd($price, $from_currency) returns $res";
            return $res;
        });

    $account_balance_limit = $client->get_limit({'for' => 'account_balance'});
    is($account_balance_limit, 300000, 'Correct account balance limit');

    $daily_turnover_limit = $client->get_limit({'for' => 'daily_turnover'});
    is($daily_turnover_limit, 500000, 'Correct turnover limit');

    $payout_limit = $client->get_limit({'for' => 'payout'});
    is($payout_limit, 50000, 'Correct payout limit');
}

$self_exclusion_open_positions_limit = $client->get_limit({'for' => 'open_positions'});
is($self_exclusion_open_positions_limit, 50, 'self exclusion open positions limit = 50');

is $client->get_limit_for_daily_losses,  undef, 'daily_losses undef';
is $client->get_limit_for_7day_losses,   undef, '7day_losses undef';
is $client->get_limit_for_7day_turnover, undef, '7day_turnover undef';

##############################################
# TEAR DOWN TEST FIXTURE
##############################################

$client->custom_max_daily_turnover(0);
$client->custom_max_acbal(0);
$client->custom_max_payout(0);
$client->save;
