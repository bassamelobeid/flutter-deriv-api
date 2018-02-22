#!/etc/rmg/bin/perl
package t::Validation::Transaction::Payment::Deposit;

use strict;
use warnings;

use Test::More;
use Test::Exception;

use Client::Account;
use Client::Account::Payments;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

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

my $client = Client::Account->register_and_return_new_client($client_details);
$client->set_default_account('USD');

$client->cashier_setting_password('12345');
throws_ok { $client->validate_payment(%deposit) } qr/Client has set the cashier password/, 'Client cashier is locked by himself.';
$client->cashier_setting_password('');

$client->set_status('unwelcome', 'calum', '..dont like you, sorry.');
$client->save;

throws_ok { $client->validate_payment(%deposit) } qr/Deposits blocked/, 'cannot deposit when unwelcome.';

$client->clr_status('unwelcome');
$client->save;

ok $client->validate_payment(%deposit), 'can deposit when not unwelcome.';

$client->set_status('disabled', 'calum', '..dont like you, sorry.');
$client->save;

throws_ok { $client->validate_payment(%deposit) } qr/Client is disabled/, 'cannot deposit when disabled.';

$client->clr_status('disabled');
$client->save;

ok $client->validate_payment(%deposit), 'can deposit when not disabled.';

$client->set_status('cashier_locked', 'calum', '..dont like you, sorry.');
$client->save;

throws_ok { $client->validate_payment(%deposit) } qr/Client's cashier is locked/, 'cannot deposit when cashier is locked.';

$client->clr_status('cashier_locked');
$client->save;

ok $client->validate_payment(%deposit), 'can deposit when not cashier locked.';

throws_ok { $client->validate_payment(%deposit, amount => 1_000_000) } qr/Balance would exceed/,
    'cannot deposit an amount that puts client over maximum balance.';

ok(!$client->get_status('unwelcome'), 'CR client not unwelcome prior to first-deposit');
$client->payment_free_gift(%deposit);
ok(!$client->get_status('unwelcome'), 'CR client still not unwelcome after first-deposit');

done_testing();
