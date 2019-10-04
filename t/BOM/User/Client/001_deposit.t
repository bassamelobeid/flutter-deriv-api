#!/etc/rmg/bin/perl
package t::Validation::Transaction::Payment::Deposit;

use strict;
use warnings;

use Test::More;
use Test::Exception;

use BOM::User::Client;
use BOM::User::Client::Payments;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User;
use BOM::User::Password;

use Date::Utility;

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $client_details = {
    broker_code     => 'CR',
    residence       => 'au',
    client_password => 'x',
    last_name       => 'shuwnyuan',
    first_name      => 'tee',
    email           => 'shuwnyuan@regentmarkets.com',
    salutation      => 'Ms',
    address_line_1  => 'ADDR 1',
    address_city    => 'Segamat',
    phone           => '+60123456789',
    secret_question => "Mother's maiden name",
    secret_answer   => 'blah',
};

my %deposit = (
    currency     => 'USD',
    amount       => 1_000,
    remark       => 'here is money',
    payment_type => 'free_gift'
);

my $client = $user->create_client(%$client_details);
$client->set_default_account('USD');

$client->status->set('unwelcome', 'calum', '..dont like you, sorry.');

throws_ok { $client->validate_payment(%deposit) } qr/Deposits blocked/, 'cannot deposit when unwelcome.';

$client->status->clear_unwelcome;

ok $client->validate_payment(%deposit), 'can deposit when not unwelcome.';

$client->status->set('disabled', 'calum', '..dont like you, sorry.');

throws_ok { $client->validate_payment(%deposit) } qr/Client is disabled/, 'cannot deposit when disabled.';

$client->status->clear_disabled;

ok $client->validate_payment(%deposit), 'can deposit when not disabled.';

$client->status->set('cashier_locked', 'calum', '..dont like you, sorry.');

throws_ok { $client->validate_payment(%deposit) } qr/Client's cashier is locked/, 'cannot deposit when cashier is locked.';

$client->status->clear_cashier_locked;

ok $client->validate_payment(%deposit), 'can deposit when not cashier locked.';

throws_ok { $client->validate_payment(%deposit, amount => 1_000_000) } qr/Balance would exceed/,
    'cannot deposit an amount that puts client over maximum balance.';

ok(!$client->status->unwelcome, 'CR client not unwelcome prior to first-deposit');
$client->payment_free_gift(%deposit);
ok(!$client->status->unwelcome, 'CR client still not unwelcome after first-deposit');

my $email_iom  = 'test' . rand(999) . '@binary.com';
my $passwd_iom = BOM::User::Password::hashpw('Qwerty12345');

my $user_iom = BOM::User->create(
    email    => $email_iom,
    password => $passwd_iom
);

my $client_details_iom = {
    broker_code     => 'MX',
    residence       => 'gb',
    client_password => $passwd_iom,
    last_name       => 'Test',
    first_name      => 'Test',
    email           => $email_iom,
    salutation      => 'Ms',
    address_line_1  => 'ADDR 1',
    address_city    => 'Test',
    phone           => '+60123456789',
    secret_question => "Mother's maiden name",
    secret_answer   => 'Test',
};

my %deposit_iom = (
    currency     => 'GBP',
    amount       => 1_000,
    remark       => 'credit',
    payment_type => 'free_gift'
);

my $client_iom = $user_iom->create_client(%$client_details_iom);
$client_iom->set_default_account('GBP');

ok $client_iom->validate_payment(%deposit_iom), 'can deposit when no deposit limit set.';

$client_iom->payment_free_gift(%deposit_iom);

my $start = Date::Utility->new;
my $end   = $start->plus_time_interval('1d');
$client_iom->set_exclusion->max_deposit(100);
$client_iom->set_exclusion->max_deposit_begin_date($start->date);
$client_iom->set_exclusion->max_deposit_end_date($end->date);
$client_iom->save();

throws_ok { $client_iom->validate_payment(%deposit_iom) } qr/Deposit exceeds limit./, 'cannot deposit when amount exceeds deposit limit.';

done_testing();
