use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Client;

# create client object
my $client;
Test::Exception::lives_ok { $client = BOM::Platform::Client::get_instance({'loginid' => 'CR0030'}); }
"Can create client object 'BOM::Platform::Client::get_instance({'loginid' => CR0030})'";

my $account_balance_limit = $client->get_limit({ 'for' => 'account_balance' });
is($account_balance_limit, 300000, 'balance limit = 300000');

my $daily_turnover_limit = $client->get_limit({ 'for' => 'daily_turnover' });
is($daily_turnover_limit, 200000, 'turnover limit = 200000');

my $payout_limit = $client->get_limit({ 'for' => 'payout' });
is($payout_limit, 200000, 'payout limit = 200000');
#setting

$client->custom_max_daily_turnover(222222);
$client->custom_max_acbal(111111);
$client->custom_max_payout(333333);

#print Data::Dumper::Dumper($client);

Test::Exception::lives_ok { $client->save(); } 'Can save client';

$client = undef;

#$client = BOM::Platform::Client::get_instance({'loginid' => 'CR0030'});

Test::Exception::lives_ok { $client = BOM::Platform::Client->new({'loginid' => 'CR0030'}); } "Force re-pull of client";

$account_balance_limit = $client->get_limit({ 'for' => 'account_balance' });
is($account_balance_limit, 111111, 'balance limit = 111111');

$daily_turnover_limit = $client->get_limit({ 'for' => 'daily_turnover' });
is($daily_turnover_limit, 222222, 'turnover limit = 222222');

$payout_limit = $client->get_limit({ 'for' => 'payout' });
is($payout_limit, 333333, 'payout limit = 333333');

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
