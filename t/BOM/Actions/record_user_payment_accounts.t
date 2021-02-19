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
    my $user_id = shift;

    BOM::User::PaymentRecord::_get_redis->del(    #
        BOM::User::PaymentRecord->new(user_id => $user_id)->storage_key,
        BOM::User::PaymentRecord::_build_flag_key(
            user_id => $user_id,
            name    => 'reported'
        ));
}

subtest 'record_user_payment_accounts' => sub {
    my $mock_event_actions_client = Test::MockModule->new('BOM::Event::Actions::Client');

    subtest 'when the client has not reached the payment accounts limit' => sub {
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 2;
        mailbox_clear();

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => 'XXXX',
                loginid            => $test_client->{loginid}})->get;

        is(mailbox_search(subject => qr/Allowed credit cards limit reached/), undef, 'no extra action is performed');

        redis_clear($test_client->binary_user_id);
    };

    subtest 'when the client has reached the payment accounts limit' => sub {
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 1;
        mailbox_clear();

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => 'XXXX',
                loginid            => $test_client->{loginid}})->get;

        my $email = mailbox_search(subject => qr/Allowed credit cards limit reached/);

        cmp_deeply $email->{to}, ['x-fraud@deriv.com'], 'an email is sent to x-fraud@deriv.com';

        my $loginid = $test_client->loginid;
        is $email->{body}, "The maximum allowed credit cards limit per user of 1 has been reached by $loginid.", "email's content is ok";

        # cleaning
        redis_clear($test_client->binary_user_id);
    };

    subtest 'when the client has reached the payment accounts limit for second time in the same day' => sub {
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 1;

        # with one payment, the client reaches the limit
        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => 'XXXX',
                loginid            => $test_client->{loginid}})->get;

        mailbox_clear();    # just clear the inbox, we don't actually care about this email

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => 'XXXY',
                loginid            => $test_client->{loginid}})->get;

        is(mailbox_search(subject => qr/Maximum credit cards limit reached/), undef, 'does not send any email anymore');

        redis_clear($test_client->binary_user_id);
    };

    subtest 'crypto payments should not be counted' => sub {
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 1;

        # crypto payments do not have payment_processor nor payment_method
        # see BOM::CTC::Helper#confirm_deposit
        BOM::Event::Actions::Client::payment_deposit({
                account_identifier => 'XXXX',
                loginid            => $test_client->{loginid}})->get;

        is(mailbox_search(subject => qr/Maximum credit cards limit reached/), undef, 'no email has been sent');

        BOM::Event::Actions::Client::payment_deposit({
                payment_processor  => 'X',
                payment_type       => 'CreditCard',
                account_identifier => 'XXXY',
                loginid            => $test_client->{loginid}})->get;

        my $email = mailbox_search(subject => qr/Allowed credit cards limit reached/);

        cmp_deeply $email->{to}, ['x-fraud@deriv.com'], 'an email is sent to x-fraud@deriv.com';

        redis_clear($test_client->binary_user_id);
    };
};

done_testing;
