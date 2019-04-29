use strict;
use warnings;

use Test::More tests => 4;
use Test::Exception;
use Test::Warnings;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Database::DataMapper::Payment;

# init test data
my $email       = 'test_client_xx00@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->set_default_account('USD');
$test_client->save;

my $payment_data_mapper;

subtest 'initialize' => sub {
    lives_ok {
        $payment_data_mapper = BOM::Database::DataMapper::Payment->new({
            'client_loginid' => $test_client->loginid,
            'currency_code'  => 'USD',
        });
    }
    'Expect to initialize payment datamapper';
};

subtest 'get total deposit' => sub {
    $test_client->payment_legacy_payment(
        currency     => 'USD',
        amount       => 500,
        payment_type => 'virtual_credit',
        remark       => 'virtual money deposit'
    );

    cmp_ok($payment_data_mapper->get_total_deposit(), '==', 500, 'check total deposit of account after deposit');

    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 100,
        remark   => 'free gift'
    );

    cmp_ok($payment_data_mapper->get_total_deposit(), '==', 600, 'check total deposit of account after two deposits');
};

subtest 'get total withdrawal' => sub {
    my $present_time       = Date::Utility->new();
    my $twenty_days_before = Date::Utility->new($present_time->epoch - 86400 * 20);
    my $thirty_days_before = Date::Utility->new($present_time->epoch - 86400 * 30);

    $test_client->payment_legacy_payment(
        currency     => 'USD',
        amount       => -100,
        payment_type => 'virtual_credit',
        remark       => 'virtual money withdrawal',
        payment_time => $thirty_days_before->datetime
    );

    cmp_ok($payment_data_mapper->get_total_withdrawal(), '==', 100, 'check total withdrawal after 1st withdrawal');

    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => -50,
        remark   => 'deduct free gift'
    );

    cmp_ok($payment_data_mapper->get_total_withdrawal(), '==', 150, 'check total withdrawal after two withdrawals');
    cmp_ok($payment_data_mapper->get_total_withdrawal({start_time => $twenty_days_before}), '==', 50,  'check total withdrawal, from last 20 days');
    cmp_ok($payment_data_mapper->get_total_withdrawal({exclude    => ['free_gift']}),       '==', 100, 'check total withdrawal, excluding free_gift');
    cmp_ok($payment_data_mapper->get_total_withdrawal({exclude => ['legacy_payment']}), '==', 50, 'check total withdrawal, excluding legacy_payment');
    cmp_ok(
        $payment_data_mapper->get_total_withdrawal({
                start_time => $twenty_days_before,
                exclude    => ['free_gift']}
        ),
        '==', 0,
        'check total withdrawal, excluding free_gift since last 20 days'
    );
    cmp_ok($payment_data_mapper->get_total_withdrawal({exclude => ['free_gift', 'legacy_payment']}),
        '==', 0, 'check total withdrawal, excluding free_gift and legacy_payment');
};
