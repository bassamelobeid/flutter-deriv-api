use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Data::Dump 'pp';
use feature 'say';
use BOM::Test;
use Email::Address::UseXS;
use Email::MIME::Attachment::Stripper;
use BOM::Test::Email qw/mailbox_clear mailbox_search/;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use Net::Async::Redis;
use IO::Async::Loop;
use BOM::Backoffice::MifirAutomation qw(run get_failed_ids write_failed_ids_to_csv);

my $loop      = IO::Async::Loop->new;
my $transport = Email::Sender::Simple->default_transport;

$loop->add(
    my $redis = Net::Async::Redis->new(
        uri => BOM::Config::Redis::redis_config('replicated', 'write')->{uri},
    ));

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $test_user = BOM::User->create(
    email          => $client->email,
    password       => "hello",
    email_verified => 1,
);
my $test_user_2 = BOM::User->create(
    email          => $client_2->email . "2",
    password       => "hello",
    email_verified => 1,
);

$test_user->add_client($client);
$test_user_2->add_client($client_2);

$client->citizen('es');
$client_2->citizen('es');

subtest 'Test get_failed_ids' => sub {
    my $failed_login_ids = BOM::Backoffice::MifirAutomation::get_failed_ids();
    is_deeply($failed_login_ids, [], 'No failed login ids');

    # Update the mifir id for the user
    $client->update_mifir_id();
    $client->update_mifir_id();
    $client_2->update_mifir_id();

    # Verify that the mifir id has been updated
    $failed_login_ids = BOM::Backoffice::MifirAutomation::get_failed_ids();
    $failed_login_ids = [sort @$failed_login_ids];
    # Verify that the user's login id is in the failed login ids list
    is_deeply($failed_login_ids, [$client->loginid, $client_2->loginid], 'User login id is in the failed login ids list');
};

subtest 'Test write_failed_ids_to_csv' => sub {
    my $failed_ids = ["MF90000000", "MF90000001"];
    BOM::Backoffice::MifirAutomation::write_failed_ids_to_csv($failed_ids);
    my $csv_file = "/tmp/failed_ids.csv";
    open my $fh, '<', $csv_file or die "Can't open file $csv_file: $!";
    my $csv_text = do { local $/; <$fh> };
    close $fh;

    for my $loginid ($failed_ids->@*) {
        ok $csv_text =~ qr/$loginid/;
    }
};

subtest 'Test email is sent ' => sub {
    mailbox_clear();
    my $msg = mailbox_search(subject => 'MIFIR ID update failed at');
    is($msg, undef, 'No email sent');
    my $failed_login_ids = BOM::Backoffice::MifirAutomation::get_failed_ids();
    $failed_login_ids = [sort @$failed_login_ids];
    $transport->clear_deliveries;
    is_deeply($failed_login_ids, [$client->loginid, $client_2->loginid], 'User login id is in the failed login ids list');
    BOM::Backoffice::MifirAutomation::run();
    my @deliveries = $transport->deliveries;
    my $email      = $deliveries[-1]{email};
    my $subject    = $email->get_header('Subject');
    is($subject, 'MIFIR ID update failed at ' . Date::Utility::today()->date, 'Email subject is correct');
    my @attachments = Email::MIME::Attachment::Stripper->new($email->object)->attachments;
    is($attachments[0]->{content_type}, "text/csv",       'Email attachment is correct');
    is($attachments[0]->{filename},     "failed_ids.csv", 'Email attachment is correct');

    for my $loginid (@$failed_login_ids) {
        ok $attachments[0]->{payload} =~ qr/$loginid/;
    }

    $failed_login_ids = BOM::Backoffice::MifirAutomation::get_failed_ids();
    is_deeply($failed_login_ids, [], 'No failed login ids');

};

done_testing();

