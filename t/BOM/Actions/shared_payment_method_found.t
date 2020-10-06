use strict;
use warnings;

use Test::More;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;
use BOM::Event::Process;
use BOM::Test::Email qw(mailbox_clear);
use BOM::Platform::Context::Request;
use BOM::Platform::Context qw(request);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test1@bin.com',
});

my $email = $test_client->email;
my $user  = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);
$user->add_client($test_client);

my $shared_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test2@bin.com',
});
my $shared_user = BOM::User->create(
    email          => $shared_client->email,
    password       => "hello",
    email_verified => 1,
);
$shared_user->add_client($shared_client);

my $action_handler = BOM::Event::Process::get_action_mappings()->{shared_payment_method_found};

subtest 'Shared PM event' => sub {
    # Mocking send_email
    my @emails;
    my @ask_poi;

    my $mocker_event = Test::MockModule->new('BOM::Event::Actions::Client');
    $mocker_event->mock(
        'send_email',
        sub {
            my $args = shift;
            push @emails,  $args->{to};
            push @ask_poi, $args->{template_args}->{ask_poi};
            return $mocker_event->original('send_email')->($args);
        });

    my $mocker_client = Test::MockModule->new(ref($shared_client));
    $mocker_client->mock(
        'source',
        sub {
            # Deriv App Id
            return 11780;
        });

    mailbox_clear();
    $action_handler->({
            client_loginid => $test_client->loginid,
            shared_loginid => $shared_client->loginid,
        })->get;

    my @emails_sent = BOM::Test::Email::email_list();

    is scalar @emails_sent, 2, 'Two emails sent';
    is $test_client->email, $emails[0], 'Sent to the client email address';
    ok $test_client->status->cashier_locked,        'Client has cashier_locked status';
    ok $test_client->status->shared_payment_method, 'Client has shared_payment_method status';
    ok $test_client->status->allow_document_upload, 'Client has allow_document_upload status';
    ok $ask_poi[0], 'E-mail has Upload Documents link';

    is $shared_client->email, $emails[1], 'Sent to the shared email address';
    ok $shared_client->status->cashier_locked,        'shared client has cashier_locked status';
    ok $shared_client->status->shared_payment_method, 'shared client has shared_payment_method status';
    ok $shared_client->status->allow_document_upload, 'shared has allow_document_upload status';
    ok $ask_poi[1], 'E-mail has Upload Documents link';
    $mocker_event->unmock_all;
    $mocker_client->unmock_all;
};

subtest 'Already age verified client' => sub {
    # Mocking send_email
    my @emails;
    my @ask_poi;

    my $mocker_event = Test::MockModule->new('BOM::Event::Actions::Client');
    $mocker_event->mock(
        'send_email',
        sub {
            my $args = shift;
            push @emails,  $args->{to};
            push @ask_poi, $args->{template_args}->{ask_poi};
            return $mocker_event->original('send_email')->($args);
        });
    my $mocker_client = Test::MockModule->new(ref($shared_client));
    $mocker_client->mock(
        'source',
        sub {
            # Deriv App Id
            return 11780;
        });

    my $mocker_status = Test::MockModule->new(ref($test_client->status));
    $mocker_status->mock(
        'age_verification',
        sub {
            return 1;
        });

    $test_client->status->clear_allow_document_upload;
    $test_client->status->clear_cashier_locked;
    $test_client->status->clear_shared_payment_method;

    $shared_client->status->clear_allow_document_upload;
    $shared_client->status->clear_cashier_locked;
    $shared_client->status->clear_shared_payment_method;

    mailbox_clear();
    $action_handler->({
            client_loginid => $test_client->loginid,
            shared_loginid => $shared_client->loginid,
        })->get;

    my @emails_sent = BOM::Test::Email::email_list();

    is scalar @emails_sent, 2, 'Two emails sent';
    is $test_client->email, $emails[0], 'Sent to the client email address';
    ok $test_client->status->cashier_locked,        'Client has cashier_locked status';
    ok $test_client->status->shared_payment_method, 'Client has shared_payment_method status';
    ok !$test_client->status->allow_document_upload, 'Client does not have allow_document_upload status';
    ok !$ask_poi[0], 'E-mail does not have Upload Documents link';

    is $shared_client->email, $emails[1], 'Sent to the shared email address';
    ok $shared_client->status->cashier_locked,        'shared client has cashier_locked status';
    ok $shared_client->status->shared_payment_method, 'shared client has shared_payment_method status';
    ok !$shared_client->status->allow_document_upload, 'shared does not have allow_document_upload status';
    ok !$ask_poi[0], 'E-mail does not have Upload Documents link';
    $mocker_event->unmock_all;
    $mocker_client->unmock_all;
};

done_testing();
