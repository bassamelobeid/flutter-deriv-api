use strict;
use warnings;

use Test::Fatal;
use Test::Deep;
use Test::More;
use Test::MockModule;

use BOM::Config;
use BOM::Event::Actions::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email;
use BOM::Config::Runtime;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::User::PaymentRecord;
use Digest::SHA qw/sha256_hex/;

my $app_config = BOM::Config::Runtime->instance->app_config;

my $mock_segment = Test::MockModule->new('WebService::Async::Segment::Customer');
$mock_segment->redefine(
    'track' => sub {
        return Future->done(1);
    });

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test1@bin.com',
});

my $user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);

$user->add_client($test_client);

subtest 'record_user_payment_accounts' => sub {
    subtest 'records written' => sub {
        my $pr = BOM::User::PaymentRecord->new(user_id => $test_client->binary_user_id);

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => sha256_hex('0x01'),
                loginid            => $test_client->{loginid}})->get;

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'Y',
                payment_type       => 'CreditCard',
                account_identifier => sha256_hex('0x02'),
                loginid            => $test_client->{loginid}})->get;

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'Z',
                payment_type       => 'CreditCard',
                account_identifier => sha256_hex('0x03'),
                loginid            => $test_client->{loginid}})->get;

        my $records = $pr->get_raw_payments(30);

        cmp_bag $records,
            [
            'X||CreditCard|1789c2b4e7983c7eff63265975b2a4d20d237c1fc69681f8a086f60008c2ab29',
            'Y||CreditCard|1f902dee07311bd6486d8eb5da95f9037d000b1815bbacf9c11e7376b695fdfe',
            'Z||CreditCard|fc9fb9f0836f51a4b1591aece9a2bfae3aa0dd8d629ae2feb70a11cc7ae9dabe',
            ],
            'Expected records added';
    };
};

done_testing;
