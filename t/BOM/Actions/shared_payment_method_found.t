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

my $test_client_MF = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
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
my @track_args;
my $payment_method      = 'VISA';
my $payment_method_text = join(' ', '| Payment method:', $payment_method);

my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{shared_payment_method_found};

subtest 'Shared PM event' => sub {

    my $mocker_client = Test::MockModule->new(ref($shared_client));
    $mocker_client->mock(
        'source',
        sub {
            # Deriv App Id
            return 11780;
        });

    $action_handler->({
            client_loginid => $test_client->loginid,
            shared_loginid => $shared_client->loginid,
            payment_method => $payment_method,
        })->get;

    ok $test_client->status->cashier_locked,        'Client has cashier_locked status';
    ok $test_client->status->shared_payment_method, 'Client has shared_payment_method status';
    ok $test_client->status->allow_document_upload, 'Client has allow_document_upload status';

    ok $shared_client->status->cashier_locked,        'shared client has cashier_locked status';
    ok $shared_client->status->shared_payment_method, 'shared client has shared_payment_method status';
    ok $shared_client->status->allow_document_upload, 'shared has allow_document_upload status';
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
                        payment_method => $payment_method,
                    })->get;
                # Replace text from "| Payment method" till the end with an empty string
                $current_reason =~ s/\| Payment method.*$//;

                is $test_client->status->_get('shared_payment_method')->{reason},
                    join(' ', $current_reason, $next_client->loginid, $payment_method_text),
                    'Test client shared reason is OK';
                is $next_client->status->_get('shared_payment_method')->{reason},
                    join(' ', 'Shared with:', $test_client->loginid, $payment_method_text),
                    'Next client shared reason is OK';

                subtest 'Repeated loginid should not be stacked' => sub {
                    my $current_reason = $test_client->status->reason('shared_payment_method');

                    $action_handler->({
                            client_loginid => $test_client->loginid,
                            shared_loginid => $next_client->loginid,
                            payment_method => $payment_method,
                        })->get;

                    is $test_client->status->reason('shared_payment_method'), $current_reason, 'Repeated loginid is not stacked';
                };
            };
        }
        $user->add_client($test_client_MF);
        $test_client_MF->account('EUR');

        subtest 'Shared PM loginid list with random reasons from CS' => sub {
            my %reasons = (
                CR9003003  => 'Shared payment method - CR9003003 with 343434343**4343434343 and CR900301',
                MLT9999999 => 'Shared payment method - MLT9003003 with some card - MX9044,ML9999999,MX24242,CH34343',
                MX990909   => 'Shared payment method - CR10000000 with that payment method #35935893',
                MF8888888  => 'Sharing payment method - ZP (random number here) with CR1790630',
            );

            for my $new_loginid (sort keys %reasons) {
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
                            payment_method => $payment_method,
                        })->get;

                    # Replace text from "| Payment method" till the end with an empty string
                    $reason =~ s/\| Payment method.*$//;

                    # Check if the new loginid is already part of the reason
                    my $new_test_reason =
                        index($reason, $new_loginid) >= 0
                        ? $reason
                        : $reason . ' ' . join(',', sort $next_client->loginid, $test_client_MF->loginid) . ' ' . $payment_method_text;

                    is $test_client->status->_get('shared_payment_method')->{reason}, $new_test_reason, 'Test client shared reason is OK';
                    is $next_client->status->_get('shared_payment_method')->{reason},
                        join(' ', 'Shared with:', (join ',', sort($test_client->loginid, $test_client_MF->loginid)), $payment_method_text),
                        'Next client shared reason is OK';
                };
            }
        };
    };
};

subtest 'multiple loginids sent in params' => sub {
    my $shared_client_another = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test3@bin.com',
    });
    my $shared_user_another = BOM::User->create(
        email          => $shared_client_another->email,
        password       => "hello",
        email_verified => 1,
    );
    $shared_user_another->add_client($shared_client_another);

    my $mocker_client = Test::MockModule->new(ref($shared_client));
    $mocker_client->mock(
        'source',
        sub {
            # Deriv App Id
            return 11780;
        });

    my $mocker_client_another = Test::MockModule->new(ref($shared_client_another));
    $mocker_client_another->mock(
        'source',
        sub {
            # Deriv App Id
            return 11780;
        });

    $test_client->status->clear_shared_payment_method;

    $action_handler->({
            client_loginid => $test_client->loginid,
            shared_loginid => $shared_client->loginid . ',' . $shared_client_another->loginid,
            payment_method => $payment_method,
        })->get;

    ok $test_client->status->cashier_locked,        'Client has cashier_locked status';
    ok $test_client->status->shared_payment_method, 'Client has shared_payment_method status';
    ok $test_client->status->allow_document_upload, 'Client has allow_document_upload status';

    is $test_client->status->shared_payment_method->{reason},
          'Shared with: '
        . join(',', sort $shared_client->loginid, $shared_client_another->loginid, $test_client_MF->loginid) . ' '
        . $payment_method_text,
        'the status reason contains both the shared clients loginids';

    ok $shared_client->status->cashier_locked,        'shared client has cashier_locked status';
    ok $shared_client->status->shared_payment_method, 'shared client has shared_payment_method status';
    ok $shared_client->status->allow_document_upload, 'shared has allow_document_upload status';

    ok $shared_client_another->status->cashier_locked,        'shared client has cashier_locked status';
    ok $shared_client_another->status->shared_payment_method, 'shared client has shared_payment_method status';
    ok $shared_client_another->status->allow_document_upload, 'shared has allow_document_upload status';

    is $shared_client_another->status->shared_payment_method->{reason},
        'Shared with: ' . join(',', sort $shared_client->loginid, $test_client->loginid, $test_client_MF->loginid) . ' ' . $payment_method_text,
        'Correct reason for shared payment method';

    $mocker_client->unmock_all;
    $mocker_client_another->unmock_all;
};

subtest 'check status is copied to both account in case of diel account' => sub {

    my $user_from = BOM::User->create(
        email          => 'test_from@bin.com',
        password       => 'x',
        email_verified => 1,
    );

    my $client_from = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test_from@bin.com',
    });

    $user_from->add_client($client_from);

    my $shared_diel_user = BOM::User->create(
        email          => 'test_diel@bin.com',
        password       => 'x',
        email_verified => 1,
    );

    my $shared_diel_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $shared_diel_user->id,
    });

    my $shared_diel_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        binary_user_id => $shared_diel_user->id,
    });

    $shared_diel_user->add_client($shared_diel_client_cr);
    $shared_diel_user->add_client($shared_diel_client_mf);

    my $user_side_effect_another = BOM::User->create(
        email          => 'side_effect@bin.com',
        password       => 'x',
        email_verified => 1,
    );

    my $client_side_effect_another = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user_side_effect_another->id,
    });

    $user_side_effect_another->add_client($client_side_effect_another);

    # Mocking send_email
    my @emails;
    my @ask_poi;

    $client_from->status->clear_shared_payment_method;

    my @emissions;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->redefine(
        'emit' => sub {
            my ($event, $args) = @_;
            push @emissions,
                {
                type    => $event,
                details => $args
                };
        });
    $action_handler->({
            client_loginid => $client_from->loginid,
            shared_loginid => $shared_diel_client_mf->loginid,
            payment_method => $payment_method,
        })->get;

    is scalar @emissions, 2, "Two events are send";

    foreach my $event (@emissions) {
        is $event->{type}, 'shared_payment_method_email_notification',
            "track event shared_payment_method_email_notification fired successfully for client $event->{details}->{loginid}";
    }

    ok $client_from->status->cashier_locked,        'Client has cashier_locked status';
    ok $client_from->status->shared_payment_method, 'Client has shared_payment_method status';
    ok $client_from->status->allow_document_upload, 'Client has allow_document_upload status';

    is $client_from->status->shared_payment_method->{reason},
        'Shared with: ' . join(',', sort $shared_diel_client_mf->loginid, $shared_diel_client_cr->loginid) . ' ' . $payment_method_text,
        'the status reason contains both the shared clients loginids';

    ok $shared_diel_client_cr->status->cashier_locked,        'shared client has cashier_locked status';
    ok $shared_diel_client_cr->status->shared_payment_method, 'shared client has shared_payment_method status';
    ok $shared_diel_client_cr->status->allow_document_upload, 'shared has allow_document_upload status';

    is $shared_diel_client_cr->status->shared_payment_method->{reason}, 'Shared with: ' . $client_from->loginid . ' ' . $payment_method_text,
        'Correct reason for shared payment method';

    ok $shared_diel_client_mf->status->cashier_locked,        'shared client has cashier_locked status';
    ok $shared_diel_client_mf->status->shared_payment_method, 'shared client has shared_payment_method status';
    ok $shared_diel_client_mf->status->allow_document_upload, 'shared has allow_document_upload status';

    is $shared_diel_client_mf->status->shared_payment_method->{reason}, 'Shared with: ' . $client_from->loginid . ' ' . $payment_method_text,
        'Correct reason for shared payment method';

    ok !$client_side_effect_another->status->cashier_locked,        'Side effect client has no cashier_locked status';
    ok !$client_side_effect_another->status->shared_payment_method, 'Side effect client has no shared_payment_method status';
    ok !$client_side_effect_another->status->allow_document_upload, 'Side effect client has no allow_document_upload status';

    $mock_events->unmock_all;

};

subtest 'Already age verified client' => sub {

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

    $action_handler->({
            client_loginid => $test_client->loginid,
            shared_loginid => $shared_client->loginid,
            payment_method => $payment_method,
        })->get;

    ok $test_client->status->cashier_locked,         'Client has cashier_locked status';
    ok $test_client->status->shared_payment_method,  'Client has shared_payment_method status';
    ok !$test_client->status->allow_document_upload, 'Client does not have allow_document_upload status';

    ok $shared_client->status->cashier_locked,         'shared client has cashier_locked status';
    ok $shared_client->status->shared_payment_method,  'shared client has shared_payment_method status';
    ok !$shared_client->status->allow_document_upload, 'shared does not have allow_document_upload status';

    $mocker_client->unmock_all;
};

subtest 'wallets' => sub {

    my $wallet1 =
        BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW', account_type => 'doughflow', email => 'wallet1@test.com'});
    BOM::User->create(
        email    => $wallet1->email,
        password => 'x'
    )->add_client($wallet1);
    my $wallet1_loginid = $wallet1->loginid;

    my $wallet2 =
        BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW', account_type => 'doughflow', email => 'wallet2@test.com'});
    BOM::User->create(
        email    => $wallet2->email,
        password => 'x'
    )->add_client($wallet2);
    my $wallet2_loginid = $wallet2->loginid;

    $action_handler->({
            client_loginid => $wallet1->doughflow_pin,
            shared_loginid => $wallet2->doughflow_pin,
            payment_method => 'xyz',
        })->get;

    ok $wallet1->status->cashier_locked,        'Sharee has cashier_locked status';
    ok $wallet1->status->shared_payment_method, 'Sharee shared_payment_method status';
    like $wallet1->status->shared_payment_method->{reason}, qr/$wallet2_loginid/, 'shared_payment_method reason contains shared loginid';
    ok $wallet1->status->allow_document_upload, 'Sharee has allow_document_upload status';

    ok $wallet2->status->cashier_locked,        'Sharer has cashier_locked status';
    ok $wallet2->status->shared_payment_method, 'Sharer has shared_payment_method status';
    like $wallet2->status->shared_payment_method->{reason}, qr/$wallet1_loginid/, 'shared_payment_method reason contains sharee loginid';
    ok $wallet2->status->allow_document_upload, 'Sharer has allow_document_upload status';
};

done_testing();
