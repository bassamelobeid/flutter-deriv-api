use strict;
use warnings;

use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Event::Actions::Client;

use BOM::Test::Email;

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

mailbox_clear();

BOM::Event::Actions::Client::_email_client_age_verified($test_client);

my $msg = mailbox_search(subject => qr/Age and identity verification/);

like($msg->{body}, qr/Dear bRaD pItT/, "Correct user in message");

like($msg->{body}, qr~https://www.binary.com/en/contact.html~, "Url Added");

mailbox_clear();

my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
});

BOM::Event::Actions::Client::_email_client_age_verified($test_client_mx);

$msg = mailbox_search(subject => qr/Age and identity verification/);
is($msg, undef, 'No email for non CR account');

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
BOM::Event::Actions::Client::email_client_account_verification({loginid => $test_client_cr->loginid});

$msg = mailbox_search(subject => qr/Account verification/);

like($msg->{body}, qr/verified your account/, "Correct message");
like($msg->{body}, qr~https://www.binary.com/en/contact.html~, "Url Added");

done_testing

