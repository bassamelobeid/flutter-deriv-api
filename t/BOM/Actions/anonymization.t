use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Event::Actions::Anonymization;
use BOM::Test;
use BOM::Test::Email;
use BOM::Config::Runtime;
use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Platform::Context;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Utility qw(random_email_address);
use JSON::MaybeUTF8 qw(decode_json_utf8);

subtest client_anonymization => sub {
    my $BRANDS = BOM::Platform::Context::request()->brand();

    # Mock BOM::User module
    my $mock_user_module = Test::MockModule->new('BOM::User');
    $mock_user_module->mock('valid_to_anonymize', sub { return 0 });

    my $user = BOM::User->create(
        email    => random_email_address,
        password => BOM::User::Password::hashpw('password'));

    # Add a CR client to the user
    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        date_joined => Date::Utility->new()->_minus_years(10)->datetime_yyyymmdd_hhmmss,
    });
    $user->add_client($cr_client);

    my $result = BOM::Event::Actions::Anonymization::anonymize_client()->get;
    is $result, undef, "Return undef when loginid is not provided.";

    mailbox_clear();
    $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $cr_client->loginid});
    my $msg = mailbox_search(subject => qr/Anonymization report for/);

    # It should send an notification email to compliance
    like($msg->{subject}, qr/Anonymization report for \d{4}-\d{2}-\d{2}/, qq/Compliance receive an email if user shouldn't anonymize./);
    like($msg->{body},    qr/has at least one active client/,             qq/Compliance receive an email if user shouldn't anonymize./);

    mailbox_clear();
    $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => 'MX009'});
    $msg    = mailbox_search(subject => qr/Anonymization report for/);

    # It should send an notification email to compliance
    like($msg->{subject}, qr/Anonymization report for \d{4}-\d{2}-\d{2}/, qq/Compliance receive an report of anonymization./);
    like($msg->{body}, qr/Getting client object failed. Please check if loginid is correct or client exist./, qq/user not found failure/);

    cmp_deeply($msg->{to}, [$BRANDS->emails('compliance')], qq/Email should send to the compliance team./);
};

subtest client_anonymization_vrtc_without_siblings => sub {
    my $BRANDS = BOM::Platform::Context::request()->brand();

    my $user = BOM::User->create(
        email    => random_email_address,
        password => BOM::User::Password::hashpw('password'));

    # Add a VRTC client to the user
    my $vrtc_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        date_joined => Date::Utility->new()->_minus_months(1)->datetime_yyyymmdd_hhmmss,
    });
    $user->add_client($vrtc_client);

    # Mock BOM::Event::Actions::Anonymization module
    my $mock_anonymization = Test::MockModule->new('BOM::Event::Actions::Anonymization');
    $mock_anonymization->mock('_send_anonymization_report', sub { return 1 });

    # Bypass CloseIO API calling and mock error response
    my $mock_closeio = Test::MockModule->new('BOM::Platform::CloseIO');
    $mock_closeio->mock('anonymize_user', 0);

    # Mock BOM::Event::Actions::CustomerIO with an error on anonymization.
    my $mock_customerio = Test::MockModule->new('BOM::Event::Actions::CustomerIO');
    $mock_customerio->mock('anonymize_user', sub { return Future->fail(0) });

    # mock BOM::Platform::Desk error response
    my $mock_s3_desk = Test::MockModule->new('BOM::Platform::Desk');
    $mock_s3_desk->mock(
        'anonymize_user',
        sub {
            return Future->fail(0);
        });

    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $vrtc_client->loginid});
    ok($result, 'Returns 1 after user anonymized.');

    # Retrieve anonymized user from database by id
    my @anonymized_clients = $user->clients(include_disabled => 1);

    isnt $_->email, lc($_->loginid . '@deleted.binary.user'), 'Email was NOT anonymized' for @anonymized_clients;

    # Bypass CloseIO API calling and mock success response
    $mock_closeio->mock('anonymize_user', 1);

    # Mock BOM::Event::Actions::CustomerIO with success on anonymization.
    $mock_customerio->mock('anonymize_user', sub { return Future->done(1) });

    # mock BOM::Platform::Desk success response
    $mock_s3_desk->mock('anonymize_user', sub { return Future->done(1) });

    $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $vrtc_client->loginid});
    ok($result, 'Returns 1 after user anonymized.');

    # Retrieve anonymized user from database by id
    @anonymized_clients = $user->clients(include_disabled => 1);

    is $_->email, lc($_->loginid . '@deleted.binary.user'), 'Email was anonymized' for @anonymized_clients;

    ok((grep { $_->broker_code eq 'VRTC' } @anonymized_clients), 'VRTC client was anonymized');
};

subtest client_anonymization_vrtc_with_siblings => sub {
    my $BRANDS = BOM::Platform::Context::request()->brand();

    my $user = BOM::User->create(
        email    => random_email_address,
        password => BOM::User::Password::hashpw('password'));

    # Add a VRTC client to the user
    my $vrtc_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        date_joined => Date::Utility->new()->_minus_months(1)->datetime_yyyymmdd_hhmmss,
    });
    $user->add_client($vrtc_client);

    # Add a CR client to the user
    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
    });
    $user->add_client($cr_client);

    # Mock BOM::Event::Actions::Anonymization module
    my $mock_anonymization = Test::MockModule->new('BOM::Event::Actions::Anonymization');
    $mock_anonymization->mock('_send_anonymization_report', sub { return 1 });

    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $vrtc_client->loginid});
    ok($result, 'Returns 1 after user anonymized.');

    # Retrieve anonymized user from database by id
    my @anonymized_clients = $user->clients(include_disabled => 1);

    isnt $_->email, lc($_->loginid . '@deleted.binary.user'), 'Email was NOT anonymized' for @anonymized_clients;

};

subtest bulk_anonymization => sub {
    my $BRANDS = BOM::Platform::Context::request()->brand();
    my (@lines, @clients, @users);
    # Mock BOM::User module
    my $mock_user_module = Test::MockModule->new('BOM::User');
    $mock_user_module->mock('valid_to_anonymize', sub { return 0 });

    # Create an array of active loginids to be like csv read output.
    for (my $i = 0; $i <= 5; $i++) {
        $users[$i] = BOM::User->create(
            email    => random_email_address,
            password => BOM::User::Password::hashpw('password'));

        # Add a CR client to the user
        $clients[$i] = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            date_joined => Date::Utility->new()->_minus_years(10)->datetime_yyyymmdd_hhmmss,
        });
        $users[$i]->add_client($clients[$i]);
        push @lines, [$clients[$i]->loginid];
    }
    my $result = BOM::Event::Actions::Anonymization::bulk_anonymization()->get;
    is $result, undef, "Return undef when client's list is not provided.";

    mailbox_clear();
    $result = BOM::Event::Actions::Anonymization::bulk_anonymization({'data' => \@lines});
    my $msg = mailbox_search(subject => qr/Anonymization report for/);

    # It should send an notification email to compliance
    like($msg->{subject}, qr/Anonymization report for \d{4}-\d{2}-\d{2}/, qq/Compliance report including failures and successes./);
    like($msg->{body},    qr/has at least one active client/,             qq/Failure reason is correct/);
    cmp_deeply($msg->{to}, [$BRANDS->emails('compliance')], qq/Email should send to the compliance team./);

    $mock_user_module->mock('valid_to_anonymize', sub { return 1 });

    # Bypass CloseIO API calling and mock error response
    my $mock_closeio = Test::MockModule->new('BOM::Platform::CloseIO');
    $mock_closeio->mock('anonymize_user', 0);

    # Mock BOM::Event::Actions::CustomerIO with an error on anonymization.
    my $mock_customerio = Test::MockModule->new('BOM::Event::Actions::CustomerIO');
    $mock_customerio->mock('anonymize_user', sub { return Future->fail(0) });

    # mock BOM::Platform::Desk error response
    my $mock_s3_desk = Test::MockModule->new('BOM::Platform::Desk');
    $mock_s3_desk->mock('anonymize_user', sub { return Future->fail(0) });

    mailbox_clear();
    $result = BOM::Event::Actions::Anonymization::bulk_anonymization({'data' => \@lines});
    ok($result, 'Returns 1 after user anonymized.');

    $msg = mailbox_search(subject => qr/Anonymization report for/);

    # It should send an notification email to compliance
    like($msg->{subject}, qr/Anonymization report for \d{4}-\d{2}-\d{2}/, qq/Compliance report including failures and successes./);
    like($msg->{body},    qr/Anonymization failed for \d+ clients/,       qq/Failure reason is correct/);
    cmp_deeply($msg->{to}, [$BRANDS->emails('compliance')], qq/Email should send to the compliance team./);

    $mock_closeio->mock('anonymize_user', 1);

    # Mock BOM::Event::Actions::CustomerIO with success on anonymization.
    $mock_customerio->mock('anonymize_user', sub { return Future->done(1) });

    # mock BOM::Platform::Desk success response
    $mock_s3_desk->mock('anonymize_user', sub { return Future->done(1) });

    # Mock BOM::User::Client module
    my $mock_client_module = Test::MockModule->new('BOM::User::Client');
    $mock_client_module->mock('anonymize_client',                          sub { return 1 });
    $mock_client_module->mock('remove_client_authentication_docs_from_S3', sub { return 1 });

    $mock_closeio->mock('anonymize_user', 1);

    mailbox_clear();

    $result = BOM::Event::Actions::Anonymization::bulk_anonymization({'data' => \@lines});
    ok($result, 'Returns 1 after user anonymized.');

    foreach my $user (@users) {
        # Retrieve anonymized user from database by id
        my $anonymized_user    = BOM::User->new(id => $user->id);
        my @anonymized_clients = $anonymized_user->clients(include_disabled => 1);

        foreach my $anonymized_client (@anonymized_clients) {
            my $disabled_status = $anonymized_client->status->disabled;
            is($disabled_status->{staff_name}, 'system', sprintf("System disabled the client (%s).", $anonymized_client->loginid));
            is(
                $disabled_status->{reason},
                'Anonymized client',
                sprintf('Client (%s) is disabled because it was anonymized.', $anonymized_client->loginid));
        }
    }

};

subtest users_clients_will_set_to_disabled_after_anonymization => sub {
    # Mock BOM::User module
    my $mock_user_module = Test::MockModule->new('BOM::User');
    $mock_user_module->mock('valid_to_anonymize', sub { return 1 });

    # Mock BOM::User::Client module
    my $mock_client_module = Test::MockModule->new('BOM::User::Client');
    $mock_client_module->mock('anonymize_client',                          sub { return 1 });
    $mock_client_module->mock('remove_client_authentication_docs_from_S3', sub { return 1 });

    my @user_clients = ();
    $mock_client_module->mock('get_user_loginids_list', sub { return @user_clients });

    # Bypass CloseIO API calling and mock success response
    my $mock_closeio = Test::MockModule->new('BOM::Platform::CloseIO');
    $mock_closeio->mock('anonymize_user', 1);

    # Mock BOM::Event::Actions::CustomerIO with success on anonymization.
    my $mock_customerio = Test::MockModule->new('BOM::Event::Actions::CustomerIO');
    $mock_customerio->mock('anonymize_user', sub { return Future->done(1) });

    # mock BOM::Platform::Desk success response
    my $mock_s3_desk = Test::MockModule->new('BOM::Platform::Desk');
    $mock_s3_desk->mock('anonymize_user', sub { return Future->done(1) });

    my $email = random_email_address;

    my $client_details = {
        date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
        broker_code => 'VRTC',
    };

    # Create a user
    my $user = BOM::User->create(
        email    => $email,
        password => BOM::User::Password::hashpw('password'));
    my $user_id = $user->id;

    my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client($client_details);

    $client_details->{broker_code} = 'CR';
    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client($client_details);

    # Add clients to the user.
    $user->add_client($vr_client);
    $user->add_client($cr_client);

    # @user_clients used in mocking process.
    push @user_clients,
        ({
            v_buid    => $user_id,
            v_loginid => $vr_client->loginid
        },
        {
            v_buid    => $user_id,
            v_loginid => $cr_client->loginid
        });

    # Anonymize user
    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $cr_client->loginid});

    ok($result, 'Returns 1 after user anonymized.');
    # Retrieve anonymized user from database by id
    my $anonymized_user    = BOM::User->new(id => $user_id);
    my @anonymized_clients = $anonymized_user->clients(include_disabled => 1);

    foreach my $anonymized_client (@anonymized_clients) {
        my $disabled_status = $anonymized_client->status->disabled;
        is($disabled_status->{staff_name}, 'system', sprintf("System disabled the client (%s).", $anonymized_client->loginid));
        is(
            $disabled_status->{reason},
            'Anonymized client',
            sprintf('Client (%s) is disabled because it was anonymized.', $anonymized_client->loginid));
    }
};

subtest 'Anonymization disabled accounts' => sub {
    # Mock BOM::User module
    my $mock_user_module = Test::MockModule->new('BOM::User');
    $mock_user_module->mock(valid_to_anonymize => 1);

    # Mock BOM::User::Client module
    my $mock_client_module = Test::MockModule->new('BOM::User::Client');
    $mock_client_module->mock(remove_client_authentication_docs_from_S3 => 1);

    # Bypass CloseIO API calling and mock success response
    my $mock_closeio = Test::MockModule->new('BOM::Platform::CloseIO');
    $mock_closeio->mock('anonymize_user', 1);

    # Mock BOM::Event::Actions::CustomerIO with success on anonymization.
    my $mock_customerio = Test::MockModule->new('BOM::Event::Actions::CustomerIO');
    $mock_customerio->mock('anonymize_user', sub { return Future->done(1) });

    # # mock BOM::Platform::Desk success response
    my $mock_s3_desk = Test::MockModule->new('BOM::Platform::Desk');
    $mock_s3_desk->mock('anonymize_user', sub { return Future->done(1) });

    my $email = random_email_address;

    # Create a user
    my $user = BOM::User->create(
        email    => $email,
        password => BOM::User::Password::hashpw('password'));
    my $user_id = $user->id;

    my $client_details = {
        date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
        broker_code => 'VRTC',
    };
    my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client($client_details);

    $client_details->{broker_code} = 'CR';
    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client($client_details);

    # Disable CR client before anonymization
    $cr_client->status->set('disabled', 'system', 'Some reason for disabling');

    # Add clients to the user.
    $user->add_client($vr_client);
    $user->add_client($cr_client);

    # Anonymize user
    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $cr_client->loginid});
    ok($result, 'Returns 1 after user anonymized.');

    # Retrieve anonymized user from database by id
    my @anonymized_clients = $user->clients(include_disabled => 1);

    is $_->email, lc($_->loginid . '@deleted.binary.user'), 'Email was anonymized' for @anonymized_clients;

    ok((grep { $_->broker_code eq 'CR' } @anonymized_clients), 'CR client was anonymized');
};

done_testing()
