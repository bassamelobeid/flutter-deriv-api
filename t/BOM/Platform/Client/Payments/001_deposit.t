#!/etc/rmg/bin/perl
package t::Validation::Transaction::Payment::Deposit;

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockObject::Extends;

use BOM::User::Client;
use BOM::User::Client::Payments;
use BOM::Platform::Client::IDAuthentication;

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

my $mlt_client = BOM::User::Client->register_and_return_new_client({
    %$client_details,
    broker_code => 'MLT',
    residence   => 'it'
});
$mlt_client->set_default_account('EUR');

ok(!$mlt_client->get_status('unwelcome'), 'MLT client not unwelcome prior to first-deposit');
$mlt_client->payment_free_gift(%deposit, currency => 'EUR');
BOM::Platform::Client::IDAuthentication->new(client => $mlt_client)->run_authentication;
ok(!$mlt_client->get_status('unwelcome'),     'MLT client not unwelcome after first-deposit');
ok($mlt_client->get_status('cashier_locked'), 'MLT client cashier_locked after first-deposit');

my $mx_client = BOM::User::Client->register_and_return_new_client({
    %$client_details,
    broker_code => 'MX',
    residence   => 'gb'
});
$mx_client->set_default_account('USD');

ok(!$mx_client->get_status('unwelcome'), 'MX client not unwelcome prior to first-deposit');
$mx_client->payment_free_gift(%deposit, currency => 'USD');
my $v = BOM::Platform::Client::IDAuthentication->new(client => $mx_client);
Test::MockObject::Extends->new($v);
$v->mock(
    -_fetch_proveid,
    sub {
        return {kyc_summary_score => 1};
    });
$v->run_authentication;
ok($mx_client->get_status('unwelcome'), 'MX client now unwelcome after first-deposit');

done_testing();
