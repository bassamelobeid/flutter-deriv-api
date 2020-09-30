use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email;
use BOM::User;
use BOM::Event::Actions::MyAffiliate;
use BOM::Event::Utility qw(exception_logged);
use BOM::User::Password;

my $email    = 'abc' . rand . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw('test');
my $user     = BOM::User->create(
    email    => $email,
    password => $hash_pwd,
);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user->id
});
$test_client->set_default_account('USD');

$email = 'abc' . rand . '@binary.com';
my $user_deriv = BOM::User->create(
    email    => $email,
    password => $hash_pwd,
);
my $test_client_deriv = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user_deriv->id
});
$test_client_deriv->set_default_account('USD');

my $mock_myaffiliate = Test::MockModule->new('BOM::MyAffiliates');

# at MyAffiliates we are maintaining separate CLIENT_ID for deriv & binary.
#the affiliates that are associated with deriv have CLIENT_ID prefixed with deriv_
my $mtr_loginid = $test_client->loginid;
$mtr_loginid =~ s/^CR/MTR/;
my $customers    = [{"CLIENT_ID" => $test_client->loginid}, {"CLIENT_ID" => 'deriv_' . $test_client_deriv->loginid}, {"CLIENT_ID" => $mtr_loginid}];
my $affiliate_id = 1234;
$mock_myaffiliate->mock(
    'get_customers' => sub {
        return $customers;
    });
subtest "clean loginids" => sub {
    my $expected_result = [$test_client->loginid, $test_client_deriv->loginid];
    is_deeply BOM::Event::Actions::MyAffiliate::_get_clean_loginids($affiliate_id), $expected_result, 'correct loginids after clean';
};
subtest "affiliate_sync_initiated" => sub {
    mailbox_clear();
    lives_ok {
        BOM::Event::Actions::MyAffiliate::affiliate_sync_initiated({
                affiliate_id => $affiliate_id,
                mt5_login    => undef,
                email        => $test_client->email
            })->get;
    }
    "affiliate_sync_initiated no exception";

    my $msg = mailbox_search(subject => qr/Affliate $affiliate_id synchronization to mt5/);
    like($msg->{body}, qr/Synchronization to mt5 for Affiliate $affiliate_id/, "Correct user in message");

    is($msg->{from}, 'no-reply@binary.com', 'Correct from Address');
};

done_testing();
