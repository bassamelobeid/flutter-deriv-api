use strict;
use warnings;

use Test::More;
use Test::Deep;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use BOM::Event::Actions::Anonymization;
use BOM::Test;
use BOM::Test::Email;
use BOM::Test::Customer;
use BOM::Config::Runtime;
use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Platform::Context;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase          qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase          qw(:init);
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Helper::Utility                          qw(random_email_address);
use JSON::MaybeUTF8                                     qw(decode_json_utf8);
use IO::Async::Loop;
use BOM::Event::Services;
use LandingCompany::Registry;
use BOM::Platform::Doughflow;
use BOM::Service;

my $service_contexts = BOM::Test::Customer::get_service_contexts();
my $redis            = BOM::Event::Actions::Anonymization::_redis_payment_write();
my $redis_mock       = Test::MockModule->new('Net::Async::Redis');
my $df_queue         = [];
my $df_partial       = [];

$redis_mock->mock(
    'zadd',
    sub {
        push $df_queue->@*, $_[3];

        my @payload = split(/\|/, $_[3]);
        my $cli     = BOM::User::Client->new({loginid => $payload[0]});

        subtest $cli->loginid . ' DF queue' => sub {
            ok !$cli->is_virtual, 'Client added to DF queue is not virtual';
            is LandingCompany::Registry::get_currency_type($cli->currency), 'fiat',      'Currency added to DF queue is not crypto';
            is BOM::Platform::Doughflow::get_sportsbook_for_client($cli),   $payload[1], 'Expected sbook enqueued';
            push $df_partial->@*, $cli->loginid;
        };

        return $redis_mock->original('zadd')->(@_);
    });

my $mock_config = Test::MockModule->new('BOM::Config');
$mock_config->mock(
    's3' => {
        binary_desk => {
            aws_bucket            => 'dummy',
            aws_access_key_id     => 'dummy',
            aws_secret_access_key => 'dummy',
        },
        document_auth => {
            aws_bucket            => 'dummy',
            aws_access_key_id     => 'dummy',
            aws_secret_access_key => 'dummy',
        },
    });

my $mocked_emitter                 = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $user_service_anonymize_allowed = 1;

# Replace the command in the user service command map with a mocked method that allows
# us to control the return value of the anonymize_allowed command
my $response = BOM::Service::admin(
    command  => 'replace_command',
    service  => 'user',
    function => 'anonymize_allowed',
    code     => sub {
        return {
            status            => 'ok',
            command           => 'anonymize_allowed',
            anonymize_allowed => $user_service_anonymize_allowed,
        };
    },
);
is $response->{status}, 'ok', 'Mocked user service anonymize_allowed command';

subtest client_anonymization => sub {
    my $BRANDS = BOM::Platform::Context::request()->brand();

    # User service says client can't be anonymised
    $user_service_anonymize_allowed = 0;

    my $customer = BOM::Test::Customer->create(
        residence   => 'id',
        date_joined => Date::Utility->new()->_minus_years(10)->datetime_yyyymmdd_hhmmss,
        clients     => [{
                name        => 'CR',
                broker_code => 'CR'
            },
        ]);

    my $result = BOM::Event::Actions::Anonymization::anonymize_client(undef, $service_contexts)->get;
    is $result, undef, "Return undef when loginid is not provided.";

    mailbox_clear();
    $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $customer->get_client_loginid('CR')}, $service_contexts)->get;
    my $msg = mailbox_search(subject => qr/Anonymization report for/);
    # It should send an notification email to compliance
    like($msg->{subject}, qr/Anonymization report for \d{4}-\d{2}-\d{2}/, qq/Compliance receive an email if user shouldn't anonymize. (subject)/);
    like($msg->{body},    qr/has at least one active client/,             qq/Compliance receive an email if user shouldn't anonymize. (body)/);

    mailbox_clear();
    $df_partial = [];
    $result     = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => 'MX009'}, $service_contexts)->get;
    $msg        = mailbox_search(subject => qr/Anonymization report for/);

    # It should send an notification email to compliance dpo team
    like($msg->{subject}, qr/Anonymization report for \d{4}-\d{2}-\d{2}/, qq/Compliance receive an report of anonymization./);
    like($msg->{body},    qr/Getting client object failed. Please check if loginid is correct or client exist./, qq/user not found failure/);

    cmp_deeply($msg->{to}, [$BRANDS->emails('compliance_dpo')], qq/Email sent to the compliance dpo team./);

    cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';

    cmp_bag $df_partial, [], 'Nothing added to the DF queue';
};

subtest client_anonymization_vrtc_without_siblings => sub {
    my $customer = BOM::Test::Customer->create(
        residence   => 'id',
        date_joined => Date::Utility->new()->_minus_months(1)->datetime_yyyymmdd_hhmmss,
        clients     => [{
                name        => 'VRTC',
                broker_code => 'VRTC'
            },
        ]);
    my $user = $customer->get_client_object('VRTC')->user;

    my $user_connect = BOM::Database::Model::UserConnect->new;
    $user_connect->insert_connect(
        $customer->get_user_id(),
        $customer->get_email(),
        {
            user => {
                identity => {
                    provider              => 'google',
                    provider_identity_uid => "test_uid"
                }}});

    # Will fail for reasons other than its allowed
    $user_service_anonymize_allowed = 1;

    # Mock BOM::Event::Actions::Anonymization module
    my $mock_anonymization = Test::MockModule->new('BOM::Event::Actions::Anonymization');
    $mock_anonymization->mock('_send_anonymization_report', sub { return 1 });

    # Bypass CloseIO API calling and mock error response
    my $mock_closeio = Test::MockModule->new('BOM::Platform::CloseIO');
    $mock_closeio->mock('anonymize_user', 0);

    # Mock BOM::Event::Actions::CustomerIO with an error on anonymization.
    my $mock_customerio = Test::MockModule->new('BOM::Event::Actions::CustomerIO');
    $mock_customerio->mock('anonymize_user', sub { return Future->fail(0) });

    # # mock BOM::Platform::Desk error response
    my $mock_s3_desk = Test::MockModule->new('BOM::Platform::Desk');
    $mock_s3_desk->mock(_s3_client_instance => undef);
    $mock_s3_desk->mock(
        'anonymize_user',
        sub {
            return Future->fail(0);
        });

    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $customer->get_client_loginid('VRTC')}, $service_contexts)->get;
    is($result, undef, 'Returns failed after user was not anonymized.');

    # Retrieve anonymized user from database by id
    my @anonymized_clients = $user->clients(include_disabled => 1);

    isnt $_->email, lc($_->loginid . '@deleted.binary.user'), 'Email was NOT anonymized' for @anonymized_clients;

    # All is well, we want anon to work now
    $user_service_anonymize_allowed = 1;

    # Bypass CloseIO API calling and mock success response
    $mock_closeio->mock('anonymize_user', 1);

    # Mock BOM::Event::Actions::CustomerIO with success on anonymization.
    $mock_customerio->mock('anonymize_user', sub { return Future->done(1) });

    # mock BOM::Platform::Desk success response
    $mock_s3_desk->mock('anonymize_user', sub { return Future->done(1) });

    $df_partial = [];
    $result     = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $customer->get_client_loginid('VRTC')}, $service_contexts)->get;
    is($result, 1, 'Returns 1 after user anonymized.');

    # Check user social login connects anonymized
    my $connect = $user_connect->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("
                    SELECT id, email, provider_data, provider_identity_uid
                      FROM users.binary_user_connects
                     WHERE binary_user_id = ?
            ", undef, $user->{id});
        });

    is_deeply $connect,
        {
        id                    => $connect->{id},
        email                 => undef,
        provider_data         => '{}',
        provider_identity_uid => 'deleted_' . $connect->{id}
        },
        "social login connect is NOT anonymized";

    # Retrieve anonymized user from database by id
    @anonymized_clients = $user->clients(include_disabled => 1);

    is $_->email, lc($_->loginid . '@deleted.binary.user'), 'Email was anonymized' for @anonymized_clients;

    ok((grep { $_->broker_code eq 'VRTC' } @anonymized_clients), 'VRTC client was anonymized');

    cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';

    cmp_bag $df_partial, [], 'Nothing added to the DF queue';
};

subtest client_anonymization_vrtc_with_siblings => sub {
    my $customer = BOM::Test::Customer->create(
        residence   => 'id',
        date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
        clients     => [{
                name        => 'VRTC',
                broker_code => 'VRTC'
            },
            {
                name        => 'CR',
                broker_code => 'CR'
            },
        ]);
    my $user = $customer->get_client_object('VRTC')->user;

    # User service says client can't be anonymised
    $user_service_anonymize_allowed = 0;

    # Mock BOM::Event::Actions::Anonymization module
    my $mock_anonymization = Test::MockModule->new('BOM::Event::Actions::Anonymization');
    $mock_anonymization->mock('_send_anonymization_report', sub { return 1 });

    $df_partial = [];
    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $customer->get_client_loginid('VRTC')}, $service_contexts)->get;
    is($result, undef, 'Returns undef after user anonymize fails.');

    # Retrieve anonymized user from database by id
    my @anonymized_clients = $user->clients(include_disabled => 1);

    isnt $_->email, lc($_->loginid . '@deleted.binary.user'), 'Email was NOT anonymized' for @anonymized_clients;

    cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';

    cmp_bag $df_partial, [], 'Nothing added to the DF queue';
};

subtest anonymize_clients => sub {
    my $BRANDS = BOM::Platform::Context::request()->brand();
    my (@lines, @users);

    # Create an array of active loginids to be like csv read output.
    for (my $i = 0; $i <= 5; $i++) {
        my $customer = BOM::Test::Customer->create(
            residence   => 'id',
            date_joined => Date::Utility->new()->_minus_years(10)->datetime_yyyymmdd_hhmmss,
            clients     => [{
                    name        => 'CR',
                    broker_code => 'CR'
                },
            ]);
        $users[$i] = $customer->get_user_id();
        push @lines, [$customer->get_client_loginid('CR')];
    }
    my $result = BOM::Event::Actions::Anonymization::anonymize_clients(undef, $service_contexts)->get;
    is $result, undef, "Return undef when client's list is not provided.";

    mailbox_clear();
    $result = BOM::Event::Actions::Anonymization::anonymize_clients({'data' => \@lines}, $service_contexts)->get;
    my $msg = mailbox_search(subject => qr/Anonymization report for/);

    # It should send an notification email to compliance dpo team
    like($msg->{subject}, qr/Anonymization report for \d{4}-\d{2}-\d{2}/, qq/Compliance report including failures and successes./);
    like($msg->{body},    qr/has at least one active client/,             qq/Failure reason is correct/);
    cmp_deeply($msg->{to}, [$BRANDS->emails('compliance_dpo')], qq/Email should send to the compliance dpo team./);

    # User service says client can't be anonymised
    $user_service_anonymize_allowed = 0;

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
    $result = BOM::Event::Actions::Anonymization::anonymize_clients({'data' => \@lines}, $service_contexts)->get;
    is($result, 1, 'Returns 1 after user anonymized.');

    $msg = mailbox_search(subject => qr/Anonymization report for/);

    # It should send an notification email to compliance dpo team
    like($msg->{subject}, qr/Anonymization report for \d{4}-\d{2}-\d{2}/, qq/Compliance report including failures and successes./);
    like($msg->{body},    qr/Anonymization failed for \d+ clients/,       qq/Failure reason is correct/);
    cmp_deeply($msg->{to}, [$BRANDS->emails('compliance_dpo')], qq/Email should send to the compliance dpo team./);

    # User service says client is OK to be anonymised
    $user_service_anonymize_allowed = 1;

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

    $df_partial = [];

    $result = BOM::Event::Actions::Anonymization::anonymize_clients({'data' => \@lines}, $service_contexts)->get;
    is($result, 1, 'Returns 1 after user anonymized.');

    my $df_anon = [];

    foreach my $user_id (@users) {
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

            push $df_anon->@*, $anonymized_client->loginid unless $anonymized_client->is_virtual;
        }
    }

    cmp_bag $df_partial, $df_anon, 'Expected clientes added to the DF queue';

    cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';
};

subtest auto_anonymize_candidates => sub {
    my $collector_db = BOM::Database::ClientDB->new({broker_code => 'FOG'})->db->dbic;

    my @emitted_data;
    $mocked_emitter->mock(emit => sub { push @emitted_data, $_[1]->{data}->@* });

    is BOM::Event::Actions::Anonymization::auto_anonymize_candidates({}, $service_contexts)->get(), 1, 'Auto anonymization triggered sucessfully';
    is scalar @emitted_data,                                                                        0, 'Bulk anonymization is not called';

    $collector_db->run(
        ping => sub {
            $_->do(
                'Insert into users.anonymization_candidates (loginid, binary_user_id, broker_code,  foreign_server, user_can_anon, compliance_confirmation, compliance_confirmation_reason, compliance_confirmation_staff) values '
                    # single valid candidate
                    . "('CR101', 1, 'CR', 'cr', true, 'approved', 'test', 'system'),"
                    # single invlid candidates, p
                    . "('CR103', 2, 'CR', 'cr', true, 'pending', 'test reason2', 'test'),"
                    . "('CR104', 3, 'CR', 'cr', true, 'postponed', 'test reason3', 'test'),"
                    # reviewed users that cannot be anonymized anymore
                    . "('CR105', 5, 'CR', 'cr', false, 'postponed', 'test reason5', 'agent5'),"
                    . "('CR106', 6, 'CR', 'cr', false, 'approved', 'test reason6', 'agent6'),"

                    # all siblings are ready
                    . "('MF101', 11, 'MF', 'mf', true, 'approved', 'test', 'system'),"
                    . "('MF102', 11, 'MF', 'mf', true, 'approved', 'test', 'system'), "
                    # some siblings are not approved
                    . "('MF103', 12, 'mf', 'maltainvest', true, 'approved', 'test', 'system'),"
                    . "('MF104', 12, 'mf', 'maltainvest', true, 'pending', 'test', 'system'),"
                    . "('MF105', 13, 'mf', 'maltainvest', true, 'approved', 'test', 'system'),"
                    . "('MF106', 13, 'mf', 'maltainvest', true, 'postponed', 'test', 'system')"
            );
        });

    is BOM::Event::Actions::Anonymization::auto_anonymize_candidates({}, $service_contexts)->get(), 1, 'Auto anonymization triggered sucessfully';
    is scalar @emitted_data,                                                                        2, 'Anonymization is called twice';
    is_deeply \@emitted_data, [qw(CR101 MF101)],
        'Loginids are correctly passed to the anonymization process - only one of siblings account (MF101, MF102) is processed';

    my $msg = mailbox_search(subject => qr/Auto\-anonymization canceled after complinace confirmation/);
    ok $msg, 'An email was sent for the rest candidates';
    like $msg->{body}, qr/CR105.*postponed.*agent5.*test reason5/, "The postponed loginid found with it's old conformation reason";
    like $msg->{body}, qr/CR106.*approved.*agent6.*test reason6/,  "The approved loginid found with it's old conformation reason";

    my @search_candidate = $collector_db->run(
        ping => sub {
            $_->selectcol_arrayref(
                "SELECT loginid FROM users.anonymization_candidates WHERE compliance_confirmation=? AND compliance_confirmation_reason=? AND compliance_confirmation_staff=?",
                undef, 'pending', 'Retention period was reset by user activity', 'system'
            );
        })->@*;
    cmp_deeply scalar \@search_candidate, [qw/CR105 CR106/], 'The reset candidates are updated with new status and reason';

    undef @emitted_data;
    BOM::Config::Runtime->instance->app_config->compliance->auto_anonymization_daily_limit(1);
    is BOM::Event::Actions::Anonymization::auto_anonymize_candidates({}, $service_contexts)->get(), 1, 'Auto anonymization triggered sucessfully';
    is scalar @emitted_data,                                                                        1, 'Anonymization is called once';
    is_deeply \@emitted_data, [qw(CR101)], 'Canidates are limited by the dynamic app config';
    BOM::Config::Runtime->instance->app_config->compliance->auto_anonymization_daily_limit(50);

};

subtest bulk_anonymization => sub {
    my @emitted_events;
    my $mocked_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mocked_emitter->mock(emit => sub { push @emitted_events, {$_[0] => $_[1]}; });

    my $mocked_anonymization = Test::MockModule->new('BOM::Event::Actions::Anonymization');
    $mocked_anonymization->mock(MAX_ANONYMIZATION_CHUNCK_SIZE => sub { return 2; });

    subtest 'bulk_anonymization with invalid data' => sub {
        my $args = {};

        my $result = BOM::Event::Actions::Anonymization::bulk_anonymization($args, $service_contexts)->get;

        is scalar @emitted_events, 0,     'No events should be emitted when there is no data';
        is $result,                undef, 'Returns undef when there is no data';
    };

    subtest 'Data to be processed in one event' => sub {
        my $args = {'data' => ['CR101', 'MF101']};

        BOM::Event::Actions::Anonymization::bulk_anonymization($args, $service_contexts)->get;

        my $expected_events = [{'anonymize_clients', {'data' => ['CR101', 'MF101']}},];

        is_deeply(\@emitted_events, $expected_events, 'Correct events should be emitted for a small data set');
    };

    subtest 'Data to be processed in multiple events' => sub {
        my $args = {'data' => ['CR101', 'MF101', 'CR102', 'MF102']};
        undef @emitted_events;

        BOM::Event::Actions::Anonymization::bulk_anonymization($args, $service_contexts)->get;

        my $expected_events = [{'anonymize_clients', {'data' => ['CR101', 'MF101']}}, {'anonymize_clients', {'data' => ['CR102', 'MF102']}},];

        is_deeply(\@emitted_events, $expected_events, 'Correct events should be emitted for a large data set');
    };
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

    # User service says client is OK to be anonymised
    $user_service_anonymize_allowed = 1;

    # Bypass CloseIO API calling and mock success response
    my $mock_closeio = Test::MockModule->new('BOM::Platform::CloseIO');
    $mock_closeio->mock('anonymize_user', 1);

    # Mock BOM::Event::Actions::CustomerIO with success on anonymization.
    my $mock_customerio = Test::MockModule->new('BOM::Event::Actions::CustomerIO');
    $mock_customerio->mock('anonymize_user', sub { return Future->done(1) });

    # mock BOM::Platform::Desk success response
    my $mock_s3_desk = Test::MockModule->new('BOM::Platform::Desk');
    $mock_s3_desk->mock('anonymize_user', sub { return Future->done(1) });

    # Create a customer
    my $customer = BOM::Test::Customer->create(
        residence   => 'id',
        date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
        clients     => [{
                name        => 'CR',
                broker_code => 'CR'
            },
            {
                name        => 'VRTC',
                broker_code => 'VRTC'
            },
        ]);

    # @user_clients used in mocking process.
    push @user_clients,
        ({
            v_buid    => $customer->get_user_id(),
            v_loginid => $customer->get_client_loginid('VRTC'),
        },
        {
            v_buid    => $customer->get_user_id(),
            v_loginid => $customer->get_client_loginid('CR'),
        });

    # Anonymize user
    $df_partial = [];
    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $customer->get_client_loginid('CR')}, $service_contexts)->get;
    is($result, 1, 'Returns 1 after user anonymized.');

    # Retrieve anonymized user from database by id
    my $anonymized_user    = BOM::User->new(id => $customer->get_user_id());
    my @anonymized_clients = $anonymized_user->clients(include_disabled => 1);

    my $df_anon = [];

    foreach my $anonymized_client (@anonymized_clients) {
        my $disabled_status = $anonymized_client->status->disabled;
        is($disabled_status->{staff_name}, 'system', sprintf("System disabled the client (%s).", $anonymized_client->loginid));
        is(
            $disabled_status->{reason},
            'Anonymized client',
            sprintf('Client (%s) is disabled because it was anonymized.', $anonymized_client->loginid));

        push $df_anon->@*, $anonymized_client->loginid unless $anonymized_client->is_virtual;
    }

    cmp_bag $df_partial, $df_anon, 'Expected clientes added to the DF queue';

    cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';
};

subtest 'Anonymization disabled accounts' => sub {
    # User service says client is ok to be anonymized
    $user_service_anonymize_allowed = 1;

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

    # Create a customer
    my $customer = BOM::Test::Customer->create(
        residence   => 'id',
        date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
        clients     => [{
                name        => 'CR',
                broker_code => 'CR'
            },
            {
                name        => 'VRTC',
                broker_code => 'VRTC'
            },
        ]);

    $customer->get_client_object('CR')->status->set('disabled', 'system', 'Some reason for disabling');

    # Anonymize user
    $df_partial = [];

    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $customer->get_client_loginid('CR')}, $service_contexts)->get;
    is($result, 1, 'Returns 1 after user anonymized.');

    # Retrieve anonymized user from database by id
    my $user               = BOM::User->new(id => $customer->get_user_id());
    my @anonymized_clients = $user->clients(include_disabled => 1);

    is $_->email, lc($_->loginid . '@deleted.binary.user'), 'Email was anonymized' for @anonymized_clients;

    ok((grep { $_->broker_code eq 'CR' } @anonymized_clients), 'CR client was anonymized');

    cmp_bag $df_partial, [map { $_->is_virtual ? () : $_->loginid } @anonymized_clients], 'Expected clients added to the DF queue';

    cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';
};

subtest 'DF Anonymization skips crypto accounts' => sub {
    # User service says client is ok to be anonymized
    $user_service_anonymize_allowed = 1;

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

    # Create a customer
    my $customer = BOM::Test::Customer->create(
        residence   => 'id',
        date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
        clients     => [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'BTC',
            },
            {
                name        => 'VRTC',
                broker_code => 'VRTC'
            },
        ]);
    $customer->get_client_object('CR')->status->set('disabled', 'system', 'Some reason for disabling');

    # Anonymize user
    $df_partial = [];

    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $customer->get_client_loginid('CR')}, $service_contexts)->get;
    is($result, 1, 'Returns 1 after user anonymized.');

    cmp_bag $df_partial, [], 'Nothing added to the DF queue';

    cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';
};

subtest 'DF anonymization done' => sub {
    my $mock = Test::MockModule->new('BOM::Event::Actions::Anonymization');
    my $stats_inc;
    $mock->mock(
        'stats_inc',
        sub {
            my $key     = shift;
            my $content = shift;

            $stats_inc = {($key => $content), $stats_inc ? $stats_inc->%* : ()};
            return;
        });

    subtest 'empty payload' => sub {
        my $payload = {};

        mailbox_clear();
        $stats_inc = {};
        $log->clear();

        ok BOM::Event::Actions::Anonymization::df_anonymization_done($payload, $service_contexts)->get, 'Event processed';

        my $msg = mailbox_search(subject => qr/Doughflow Anonymization Report/);
        ok !$msg, 'No email was sent';

        cmp_deeply $stats_inc, {}, 'Dog was not called';
        cmp_deeply $log->msgs(), [], 'No logs generated';
    };

    subtest 'invalod loginid' => sub {
        my $payload = {CR0 => {data => 'OK'}};

        mailbox_clear();
        $stats_inc = {};
        $log->clear();

        ok BOM::Event::Actions::Anonymization::df_anonymization_done($payload, $service_contexts)->get, 'Event processed';

        my $msg = mailbox_search(subject => qr/Doughflow Anonymization Report/);
        ok !$msg, 'No email was sent';

        cmp_deeply $stats_inc, {}, 'Dog was not called';
        cmp_deeply $log->msgs(), [], 'No logs generated';
    };

    ## Create a user
    my $customer1 = BOM::Test::Customer->create(
        residence   => 'id',
        date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
        clients     => [{
                name        => 'CR',
                broker_code => 'CR',
            },
            {
                name        => 'VRTC',
                broker_code => 'VRTC'
            },
        ]);

    my $loginid = $customer1->get_client_loginid('CR');

    subtest 'DF result is OK' => sub {
        my $BRANDS  = BOM::Platform::Context::request()->brand();
        my $payload = {
            $loginid => {
                data => 'OK',
            },
        };

        mailbox_clear();
        $log->clear();
        $stats_inc = {};

        my $result = BOM::Event::Actions::Anonymization::df_anonymization_done($payload, $service_contexts)->get;

        is($result, 1, 'Returns 1 after user anonymized.');

        my $msg = mailbox_search(subject => qr/Doughflow Anonymization Report/);
        ok $msg,                 'DF anonymization report email sent';
        ok $msg->{body} =~ /OK/, 'OK message';
        cmp_deeply($msg->{to}, [$BRANDS->emails('compliance_dpo')], qq/Email should send to the compliance dpo team./);

        cmp_deeply $stats_inc,
            {
            'df_anonymization.result.success' => undef,
            },
            'Dog was called just as expected';

        cmp_deeply $log->msgs(), [], 'No logs generated for the OK response';
    };

    subtest 'DF result is error' => sub {
        my $BRANDS  = BOM::Platform::Context::request()->brand();
        my $payload = {
            $loginid => {
                data => '3 - PIN has recent (12 months) transaction activity',
            },
        };

        mailbox_clear();
        $log->clear();
        $stats_inc = {};

        my $result = BOM::Event::Actions::Anonymization::df_anonymization_done($payload, $service_contexts)->get;

        is($result, 1, 'Returns 1 after user anonymized.');

        my $msg = mailbox_search(subject => qr/Doughflow Anonymization/);
        ok $msg,                                                                     'DF anonymization report email sent';
        ok $msg->{body} =~ /3 \- PIN has recent \(12 months\) transaction activity/, 'Error message';
        cmp_deeply($msg->{to}, [$BRANDS->emails('compliance_dpo')], qq/Email should send to the compliance dpo team./);

        cmp_deeply $stats_inc,
            {
            'df_anonymization.result.error' => {tags => ["result:3 - PIN has recent (12 months) transaction activity", "loginid:$loginid"]},
            },
            'Dog was called just as expected';

        $log->contains_ok(qr/DF Anonymization error code: 3 \- PIN has recent \(12 months\) transaction activity for $loginid/,
            'Error log generated');
    };

    subtest 'DF result is to retry' => sub {
        my $payload = {
            $loginid => {
                data => '6 - New generated PIN already exists. Try executing the store procedure again.',
            },
        };

        mailbox_clear();
        $log->clear();
        $stats_inc  = {};
        $df_partial = [];

        my $result = BOM::Event::Actions::Anonymization::df_anonymization_done($payload, $service_contexts)->get;

        is($result, 1, 'Returns 1 after user anonymized.');

        my $msg = mailbox_search(subject => qr/.*/);
        ok !$msg, 'No email sent';

        cmp_deeply $stats_inc,
            {
            'df_anonymization.result.retry' => {tags => ["loginid:$loginid"]},
            },
            'Dog was called just as expected';

        $log->contains_ok(qr/DF Anonymization retry: $loginid/, 'Error log generated');

        cmp_bag $df_partial, [$loginid], 'Client added to the DF queue (retry)';

        cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';
    };

    subtest 'DF result is to retry, but max retry is hit' => sub {
        my $payload = {
            $loginid => {
                data => '6 - New generated PIN already exists. Try executing the store procedure again.',
            },
        };

        mailbox_clear();
        $log->clear();
        $stats_inc = {};
        $redis->set('DF_ANONYMIZATION_RETRY_COUNTER::' . $loginid, 100)->get;
        $df_partial = [];

        my $result = BOM::Event::Actions::Anonymization::df_anonymization_done($payload, $service_contexts)->get;

        is($result, 1, 'Returns 1 after user anonymized.');

        my $msg = mailbox_search(subject => qr/.*/);
        ok !$msg, 'No email sent';

        cmp_deeply $stats_inc,
            {
            'df_anonymization.result.max_retry' => {tags => ["loginid:$loginid"]},
            },
            'Dog was called just as expected';

        $log->contains_ok(qr/DF Anonymization max retry attempts reached: $loginid/, 'Error log generated');

        cmp_bag $df_partial, [], 'Nothing added to the DF queue';

        cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';
    };

    subtest 'Mixed results' => sub {
        ## Create a customer
        my $customer2 = BOM::Test::Customer->create(
            residence   => 'id',
            date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
            clients     => [{
                    name        => 'CR',
                    broker_code => 'CR',
                },
                {
                    name        => 'VRTC',
                    broker_code => 'VRTC'
                },
            ]);

        my $customer3 = BOM::Test::Customer->create(
            residence   => 'id',
            date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
            clients     => [{
                    name        => 'CR',
                    broker_code => 'CR',
                },
                {
                    name        => 'VRTC',
                    broker_code => 'VRTC'
                },
            ]);

        ## Create a user
        my $loginid2 = $customer2->get_client_loginid('CR');

        ## Create a user
        my $loginid3 = $customer3->get_client_loginid('CR');

        my $payload = {
            $loginid => {
                data => '6 - New generated PIN already exists. Try executing the store procedure again.',
            },
            $loginid2 => {
                data => 'OK',
            },
            $loginid3 => {
                data => '3 - PIN has recent (12 months) transaction activity',
            },
        };

        mailbox_clear();
        $log->clear();
        $stats_inc = {};
        $redis->set('DF_ANONYMIZATION_RETRY_COUNTER::' . $loginid, 100)->get;
        $df_partial = [];

        my $result = BOM::Event::Actions::Anonymization::df_anonymization_done($payload, $service_contexts)->get;

        is($result, 1, 'Returns 1 after user anonymized.');

        my $msg = mailbox_search(subject => qr/.*/);
        ok $msg, 'Email sent';
        ok $msg->{body} =~ /3 \- PIN has recent \(12 months\) transaction activity/, 'Error message';
        ok $msg->{body} =~ /OK/,                                                     'OK message';

        cmp_deeply $stats_inc,
            {
            'df_anonymization.result.max_retry' => {tags => ["loginid:$loginid"]},
            'df_anonymization.result.error'     => {tags => ["result:3 - PIN has recent (12 months) transaction activity", "loginid:$loginid3"]},
            'df_anonymization.result.success'   => undef,
            },
            'Dog was called just as expected';

        $log->contains_ok(qr/DF Anonymization max retry attempts reached: $loginid/, 'Error log generated');

        cmp_bag $df_partial, [], 'Nothing added to the DF queue';

        cmp_bag $df_queue, $redis->zrangebyscore('DF_ANONYMIZATION_QUEUE', '-Inf', '+Inf')->get, 'Clients queued for DF anonymization';
    };

    $mock->unmock_all;
};

# Restore the original method in the user service command map
$response = BOM::Service::admin(
    command  => 'restore_command',
    service  => 'user',
    function => 'anonymize_allowed',
);
is $response->{status}, 'ok', 'Restored user service anonymize_allowed command';

done_testing()
