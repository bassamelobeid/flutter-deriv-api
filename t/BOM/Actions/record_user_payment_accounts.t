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

sub redis_clear {
    my $user_id      = shift;
    my $payment_type = shift;

    BOM::User::PaymentRecord::_get_redis->del(
        BOM::User::PaymentRecord->new(
            user_id => $user_id,
        )->storage_key
    );

    my $mail_block_key = join '::', +BOM::Event::Actions::Client::PAYMENT_ACCOUNT_LIMIT_REACHED_KEY, 'PaymentType', $payment_type;
    BOM::Event::Actions::Client::_redis_replicated_write()->hdel($mail_block_key, $user_id);
}

subtest 'record_user_payment_accounts' => sub {
    my $mock_event_actions_client = Test::MockModule->new('BOM::Event::Actions::Client');

    subtest 'when the client has not reached the payment accounts limit' => sub {
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 2;
        mailbox_clear();

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => sha256_hex('XXXX'),
                loginid            => $test_client->{loginid}})->get;

        is(mailbox_search(subject => qr/Allowed limit reached on CrediCard/), undef, 'no extra action is performed');

        redis_clear($test_client->binary_user_id, 'CreditCard');
    };

    subtest 'when the client has reached the payment accounts limit' => sub {
        $app_config->payments->payment_methods->high_risk(
            encode_json_utf8({
                    CreditCard => {
                        limit    => 1,
                        days     => 90,
                        siblings => [],
                    }}));

        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 1;
        mailbox_clear();

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => sha256_hex('XXXX'),
                loginid            => $test_client->{loginid}})->get;

        my $email = mailbox_search(subject => qr/Allowed limit on CreditCard/);

        cmp_deeply $email->{to}, ['x-antifraud-alerts@deriv.com'], 'an email is sent to x-antifraud-alerts@deriv.com';

        my $loginid = $test_client->loginid;
        is $email->{body}, "The maximum allowed limit on CreditCard per user of 1 has been reached by $loginid.", "email's content is ok";

        # cleaning
        redis_clear($test_client->binary_user_id, 'CreditCard');
    };

    subtest 'when the client has reached the payment accounts limit for second time in the same day' => sub {
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 1;

        # with one payment, the client reaches the limit
        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => sha256_hex('XXXX'),
                loginid            => $test_client->{loginid}})->get;

        mailbox_clear();    # just clear the inbox, we don't actually care about this email

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => sha256_hex('XXXY'),
                loginid            => $test_client->{loginid}})->get;

        is(mailbox_search(subject => qr/Maximum limit on CreditCard reached/), undef, 'does not send any email anymore');

        redis_clear($test_client->binary_user_id, 'CreditCard');
    };

    subtest 'crypto payments should not be counted' => sub {
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 1;

        # crypto payments do not have payment_processor nor payment_method
        # see BOM::CTC::Helper#confirm_deposit
        BOM::Event::Actions::Client::payment_deposit({
                account_identifier => sha256_hex('XXXX'),
                loginid            => $test_client->{loginid}})->get;

        is(mailbox_search(subject => qr/Allowed limit on CreditCard/), undef, 'no email has been sent');

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => sha256_hex('XXXY'),
                loginid            => $test_client->{loginid}})->get;

        my $email = mailbox_search(subject => qr/Allowed limit on CreditCard/);

        cmp_deeply $email->{to}, ['x-antifraud-alerts@deriv.com'], 'an email is sent to x-antifraud-alerts@deriv.com';

        redis_clear($test_client->binary_user_id, 'CreditCard');
    };

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
