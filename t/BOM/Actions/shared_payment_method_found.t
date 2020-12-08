use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;

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

    subtest 'Shared PM stacking the loginid list' => sub {
        for my $loginid (qw/CR23571113 MX23571113 MF23571113 MLT23571113/) {
            my $next_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => $loginid =~ /([A-Z]+)/,
                loginid     => $loginid,
                email       => join('', 'asdf', '+', $loginid, '@test.com'),
            });
            my $next_user = BOM::User->create(
                email          => $next_client->email,
                password       => "hello",
                email_verified => 1,
            );
            $next_user->add_client($next_client);

            subtest 'Sharing with loginid ' . $next_client->loginid => sub {
                my $current_reason = $test_client->status->_get('shared_payment_method')->{reason};
                $action_handler->({
                        client_loginid => $test_client->loginid,
                        shared_loginid => $next_client->loginid,
                    })->get;

                is $test_client->status->_get('shared_payment_method')->{reason}, join(' ', $current_reason, $next_client->loginid),
                    'Test client shared reason is OK';
                is $next_client->status->_get('shared_payment_method')->{reason}, join(' ', 'Shared with:', $test_client->loginid),
                    'Next client shared reason is OK';

                subtest 'Repeated loginid should not be stacked' => sub {
                    my $current_reason = $test_client->status->reason('shared_payment_method');

                    $action_handler->({
                            client_loginid => $test_client->loginid,
                            shared_loginid => $next_client->loginid,
                        })->get;

                    is $test_client->status->reason('shared_payment_method'), $current_reason, 'Repeated loginid is not stacked';
                };
            };
        }

        subtest 'Shared PM loginid list with random reasons from CS' => sub {
            my %reasons = (
                CR9003003  => 'Shared payment method - CR9003003 with 343434343**4343434343 and CR900301',
                MLT9999999 => 'Shared payment method - MLT9003003 with some card - MX9044,ML9999999,MX24242,CH34343',
                MX990909   => 'Shared payment method - CR10000000 with that payment method #35935893',
                MF8888888  => 'Sharing payment method - ZP (random number here) with CR1790630',
            );

            for my $new_loginid (keys %reasons) {
                my $reason = $reasons{$new_loginid};

                subtest "Sharing with loginid $new_loginid" => sub {
                    $test_client->status->upsert('shared_payment_method', 'staff', $reason);

                    my $next_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                        broker_code => $new_loginid =~ /([A-Z]+)/,
                        loginid     => $new_loginid,
                        email       => join('', 'test', '+', $new_loginid, '@test.com'),
                    });
                    my $next_user = BOM::User->create(
                        email          => $next_client->email,
                        password       => "hello",
                        email_verified => 1,
                    );
                    $next_user->add_client($next_client);

                    $action_handler->({
                            client_loginid => $test_client->loginid,
                            shared_loginid => $next_client->loginid,
                        })->get;

                    # Check if the new loginid is already part of the reason
                    my $new_test_reason = index($reason, $new_loginid) >= 0 ? $reason : join(' ', $reason, $next_client->loginid);
                    is $test_client->status->_get('shared_payment_method')->{reason}, $new_test_reason, 'Test client shared reason is OK';
                    is $next_client->status->_get('shared_payment_method')->{reason}, join(' ', 'Shared with:', $test_client->loginid),
                        'Next client shared reason is OK';
                };
            }
        };
    };
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
