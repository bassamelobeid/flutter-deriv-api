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

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->set_default_account('USD');

my $test_user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);

my $mock_myaffiliate = Test::MockModule->new('BOM::MyAffiliates');
my $customer_;
my $affiliate_id = 1234;
$mock_myaffiliate->mock(
    'get_customers' => sub {
        my $customers = [{"CLIENT_ID" => $test_client->loginid}];
        $customer_ = $customers;
        return $customers;
    });

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
