use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Log::Any::Test;
use Log::Any qw($log);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Test::Email;
use BOM::Database::UserDB;
use BOM::Database::ClientDB;
use BOM::User;
use BOM::Test::Script::OnfidoMock;
use BOM::Platform::Context qw(request);

use WebService::Async::Onfido;
use BOM::Event::Actions::Client;
use BOM::Event::Process;

my (@identify_args, @track_args);
my $segment_response = Future->done(1);
my $mock_segment     = new Test::MockModule('WebService::Async::Segment::Customer');
$mock_segment->redefine(
    'identify' => sub {
        @identify_args = @_;
        return $segment_response;
    },
    'track' => sub {
        @track_args = @_;
        return $segment_response;
    });
my $mock_brands = Test::MockModule->new('Brands');
$mock_brands->mock(
    'is_track_enabled' => sub {
        my $self = shift;
        return ($self->name eq 'deriv');
    });

my $onfido_doc = Test::MockModule->new('WebService::Async::Onfido::Document');
$onfido_doc->mock('side', sub { return undef });

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->set_default_account('USD');

my $test_user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);
$test_user->add_client($test_client);
$test_client->place_of_birth('cn');
$test_client->binary_user_id($test_user->id);
$test_client->save;

mailbox_clear();

BOM::Event::Actions::Client::_email_client_age_verified($test_client);

my $msg = mailbox_search(subject => qr/Age and identity verification/);
like($msg->{body}, qr/Dear bRaD pItT/, "Correct user in message");

like($msg->{body}, qr~https://www.binary.com/en/contact.html~, "Url Added");

like($msg->{body}, qr/Binary.com/, "Website  Added");

is($msg->{from}, 'no-reply@binary.com', 'Correct from Address');
$test_client->status->set('age_verification');

mailbox_clear();
BOM::Event::Actions::Client::_email_client_age_verified($test_client);

$msg = mailbox_search(subject => qr/Age and identity verification/);
is($msg, undef, "Didn't send email when already age verified");

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

like($msg->{body}, qr/Binary.com/, "Website  Added");
my $args = {
    document_type     => 'proofaddress',
    document_format   => 'PNG',
    document_id       => undef,
    expiration_date   => undef,
    expected_checksum => '12345',
    page_type         => undef,

};

my ($applicant, $applicant_id, $loop, $onfido);
subtest 'upload document' => sub {

    $loop = IO::Async::Loop->new;
    my $upload_info = $test_client->db->dbic->run(
        ping => sub {
            $_->selectrow_hashref(
                'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?)', undef,
                $test_client->loginid,                                                      $args->{document_type},
                $args->{document_format}, $args->{expiration_date} || undef,
                $args->{document_id} || '', $args->{expected_checksum},
                '', $args->{page_type} || '',
            );
        });

    # Redis key for resubmission flag
    use constant POA_ALLOW_RESUBMISSION_KEY_PREFIX => 'POA::ALLOW_RESUBMISSION::ID::';
    $loop->add(my $services = BOM::Event::Services->new);
    my $redis_write = $services->redis_replicated_write();
    $redis_write->set(POA_ALLOW_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id, 1)->get;    # Activate the flag

    $test_client->db->dbic->run(
        ping => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
        });

    my $mocked_action    = Test::MockModule->new('BOM::Event::Actions::Client');
    my $document_content = 'it is a proffaddress document';
    $mocked_action->mock('_get_document_s3', sub { return Future->done($document_content) });

    $loop->add(
        $onfido = WebService::Async::Onfido->new(
            token    => 'test',
            base_uri => $ENV{ONFIDO_URL}));
    BOM::Event::Actions::Client::document_upload({
            loginid => $test_client->loginid,
            file_id => $upload_info->{file_id}})->get;
    my $applicant = BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $test_client->user_id);
        });
    ok($applicant, 'There is an applicant data in db');
    $applicant_id = $applicant->{id};
    ok($applicant_id, 'applicant id ok');

    my $resubmission_flag_after = $redis_write->get(POA_ALLOW_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id)->get;
    ok !$resubmission_flag_after, 'poa resubmission flag is removed from redis after document uploading';

    my $doc = $onfido->document_list(applicant_id => $applicant_id)->as_arrayref->get->[0];
    ok($doc, "there is a document");

    my $content2;
    lives_ok {
        $content2 = $onfido->download_document(
            applicant_id => $applicant_id,
            document_id  => $doc->id
            )->get
    }
    'download doc ok';

    is($content2, $document_content, "the content is right");
};

my $check;
subtest "ready for run authentication" => sub {
    $test_client->status->clear_age_verification;
    $loop->add(my $services = BOM::Event::Services->new);
    my $redis        = $services->redis_events_write();
    my $redis_r_read = $services->redis_replicated_read();
    $redis->del(BOM::Event::Actions::Client::ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id)->get;
    lives_ok {
        BOM::Event::Actions::Client::ready_for_authentication({
                loginid      => $test_client->loginid,
                applicant_id => $applicant_id,
            })->get;
    }
    "ready_for_authentication no exception";

    $check = $onfido->check_list(applicant_id => $applicant_id)->as_arrayref->get->[0];
    ok($check, "there is a check");
    my $check_data = BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            my $sth =
                $_->selectrow_hashref('select * from users.get_onfido_checks(?::BIGINT, ?::TEXT, 1)', undef, $test_client->user_id, $applicant_id);
        });
    ok($check_data, 'get check data ok from db');
    is($check_data->{id},     $check->{id},  'check data correct');
    is($check_data->{status}, 'in_progress', 'check status is in_progress');

    my $applicant_context = $redis_r_read->exists(BOM::Event::Actions::Client::ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY . $applicant_id);
    ok $applicant_context, 'request context of applicant is present in redis';
};

my $services;
subtest "client_verification" => sub {
    $loop->add($services = BOM::Event::Services->new);
    my $redis_write = $services->redis_events_write();
    $redis_write->connect->get;
    $redis_write->del(BOM::Event::Actions::Client::ONFIDO_AGE_EMAIL_PER_USER_PREFIX . $test_client->user_id)->get;
    mailbox_clear();

    lives_ok {
        BOM::Event::Actions::Client::client_verification({
                check_url => $check->{href},
            })->get;
    }
    "client verification no exception";
    my $check_data = BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('select * from users.get_onfido_checks(?::BIGINT, ?::TEXT, 1)', undef, $test_client->user_id, $applicant_id);
        });
    ok($check_data, 'get check data ok from db');
    is($check_data->{id},     $check->{id}, 'check data correct');
    is($check_data->{status}, 'complete',   'check status is updated');
    my $report_data = BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('select * from users.get_onfido_reports(?::BIGINT, ?::TEXT)', undef, $test_client->user_id, $check->{id});
        });
    is($report_data->{check_id}, $check->{id}, 'report is correct');
    my $msg = mailbox_search(subject => qr/Automated age verification failed/);
    ok($msg, 'automated age verification failed email sent');
};

subtest "document upload request context" => sub {
    my $context = {
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => '16000'
    };
    my $req = BOM::Platform::Context::Request->new($context);
    request($req);

    $test_client->status->clear_age_verification;

    $loop->add(my $services = BOM::Event::Services->new);
    my $redis_r_read  = $services->redis_replicated_read();
    my $redis_r_write = $services->redis_replicated_write();

    lives_ok {
        BOM::Event::Actions::Client::ready_for_authentication({
                loginid      => $test_client->loginid,
                applicant_id => $applicant_id,
            })->get;
    }
    "ready for authentication emitted without exception";

    my $applicant_context = $redis_r_read->exists(BOM::Event::Actions::Client::ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY . $applicant_id);
    ok $applicant_context, 'request context of applicant is present in redis';

    my $another_context = {
        app_id     => '123',
        language   => 'FA',
        brand_name => 'binary'
    };
    my $another_req = BOM::Platform::Context::Request->new($another_context);
    request($another_req);

    my $request;
    my $mocked_action = Test::MockModule->new('BOM::Event::Actions::Client');
    $mocked_action->mock('_store_applicant_documents', sub { $request = request(); return undef });

    lives_ok {
        BOM::Event::Actions::Client::client_verification({
                check_url => $check->{href},
            })->get;
    }
    "client verification emitted without exception";

    is $context->{brand_name}, $request->brand_name, 'brand name is correct';
    is $context->{language},   $request->language,   'language is correct';
    is $context->{app_id},     $request->app_id,     'app id is correct';

    request($another_req);

    $redis_r_write->del(BOM::Event::Actions::Client::ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY . $applicant_id);
    $redis_r_write->set(BOM::Event::Actions::Client::ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY . $applicant_id, ']non json format[');

    lives_ok {
        BOM::Event::Actions::Client::client_verification({
                check_url => $check->{href},
            })->get;
    }
    "client verification emitted without exception";

    is $another_context->{brand_name}, $request->brand_name, 'brand name is correct';
    is $another_context->{language},   $request->language,   'language is correct';
    is $another_context->{app_id},     $request->app_id,     'app id is correct';
};

$onfido_doc->unmock_all();

# construct a client that upload document itself, then test  client_verification, and see uploading documents
subtest 'client_verification after upload document himself' => sub {
    my $dbic         = BOM::Database::UserDB::rose_db()->dbic;
    my $test_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        email       => 'test2@binary.com',
        broker_code => 'CR',
    });
    my $test_user2 = BOM::User->create(
        email          => $test_client2->email,
        password       => "hello",
        email_verified => 1,
    );
    $test_user2->add_client($test_client2);
    $test_client2->place_of_birth('cn');
    $test_client2->binary_user_id($test_user2->id);
    $test_client2->save;
    my $redis_write = $services->redis_events_write();
    $redis_write->connect->get;
    $redis_write->del(BOM::Event::Actions::Client::ONFIDO_REQUEST_PER_USER_PREFIX . $test_client2->user_id)->get;

    my $applicant2 = $onfido->applicant_create(
        title      => 'Mr',
        first_name => $test_client2->first_name,
        last_name  => $test_client2->last_name,
        email      => $test_client2->email,
        dob        => '1980-01-22',
        country    => 'GBR',
        addresses  => [{
                building_number => '100',
                street          => 'Main Street',
                town            => 'London',
                postcode        => 'SW4 6EH',
                country         => 'GBR',
            }
        ],
    )->get;

    $dbic->run(
        fixup => sub {
            $_->do(
                'select users.add_onfido_applicant(?::TEXT,?::TIMESTAMP,?::TEXT,?::BIGINT)',
                undef, $applicant2->id, Date::Utility->new($applicant2->created_at)->datetime_yyyymmdd_hhmmss,
                $applicant2->href, $test_client2->user_id
            );
        });

    my $doc = $onfido->document_upload(
        applicant_id    => $applicant2->id,
        filename        => "document1.png",
        type            => 'passport',
        issuing_country => 'China',
        data            => 'This is passport',
        side            => 'front',
    )->get;
    my $applicant_id2 = $applicant2->id;
    my $photo         = $onfido->live_photo_upload(
        applicant_id => $applicant_id2,
        filename     => 'photo1.jpg',
        data         => 'photo ' x 50
    )->get;

    $redis_write->del(BOM::Event::Actions::Client::ONFIDO_AGE_EMAIL_PER_USER_PREFIX . $test_client2->user_id)->get;

    my $existing_onfido_docs = $dbic->run(
        fixup => sub {
            my $result = $_->prepare('select * from users.get_onfido_documents(?::BIGINT, ?::TEXT)');
            $result->execute($test_client2->binary_user_id, $applicant_id2);
            return $result->fetchall_hashref('id');
        });

    is_deeply($existing_onfido_docs, {}, 'at first no docs in db');

    lives_ok {
        BOM::Event::Actions::Client::ready_for_authentication({
                loginid      => $test_client2->loginid,
                applicant_id => $applicant_id2,
            })->get;
    }
    "ready_for_authentication no exception";

    my $check2 = $onfido->check_list(applicant_id => $applicant_id2)->as_arrayref->get->[0];
    ok($check2, "there is a check");

    my $mocked_config = Test::MockModule->new('BOM::Config');
    $mocked_config->mock(
        s3 => sub {
            return {document_auth => {map { $_ => 1 } qw(aws_access_key_id aws_secret_access_key aws_bucket)}};
        });
    my $mocked_s3client = Test::MockModule->new('BOM::Platform::S3Client');
    $mocked_s3client->mock(upload => sub { return Future->done(1) });
    $log->clear();

    lives_ok {
        BOM::Event::Actions::Client::client_verification({
                check_url => $check2->{href},
            })->get;
    }
    "ready_for_authentication no exception";

    $existing_onfido_docs = $dbic->run(
        fixup => sub {
            my $result = $_->prepare('select * from users.get_onfido_documents(?::BIGINT, ?::TEXT)');
            $result->execute($test_client2->binary_user_id, $applicant_id2);
            return $result->fetchall_hashref('id');
        });

    my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
    my $doc_file_name = $clientdb->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare('select file_name from betonmarkets.client_authentication_document where client_loginid=? and document_type=?');
            $sth->execute($test_client2->loginid, 'photo');
            return $sth->fetchall_arrayref({})->[0]{file_name};
        });

    like($doc_file_name, qr{\.jpg$}, 'uploaded document has expected jpg extension');

    is_deeply([keys %$existing_onfido_docs], [$doc->id], 'now the doc is stored in db');

    my $mocked_user_onfido = Test::MockModule->new('BOM::User::Onfido');
    # simulate the case that 2 processes uploading same documents almost at same time.
    # at first process 1 doesn't upload document yet, so process 2 get_onfido_live_photo will return null
    # and when process 2 call db func `start_document_upload` , process 1 already uploaded file.
    # at this time process 2 should report a warn.
    $mocked_user_onfido->mock(get_onfido_live_photo   => sub { diag "in mocked get_";  return undef });
    $mocked_user_onfido->mock(store_onfido_live_photo => sub { diag "in mocked store"; return undef });

    lives_ok {
        BOM::Event::Actions::Client::client_verification({
                check_url => $check2->{href},
            })->get;
    }
    "ready_for_authentication no exception";
    $log->contains_ok(qr/Document already exists/, 'warning string is ok');

};

subtest 'sync_onfido_details' => sub {
    $applicant = $onfido->applicant_get(applicant_id => $applicant_id)->get;
    is($test_client->first_name, $applicant->{first_name}, 'the information is same at first');
    $test_client->first_name('Firstname');
    $test_client->save;
    BOM::Event::Actions::Client::sync_onfido_details({loginid => $test_client->loginid})->get;
    $applicant = $onfido->applicant_get(applicant_id => $applicant_id)->get;
    is($applicant->{first_name}, 'Firstname', 'now the name is same again');

    ok(1);

};

subtest 'signup event' => sub {

    # Data sent for virtual signup should be loginid, country and landing company. Other values are not defined for virtual
    my $virtual_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code      => 'VRTC',
        email            => 'test2@bin.com',
        first_name       => '',
        last_name        => '',
        date_of_birth    => undef,
        phone            => '',
        address_line_1   => '',
        address_line_2   => '',
        address_city     => '',
        address_state    => '',
        address_postcode => '',
    });
    my $email = $virtual_client2->email;

    my $user2 = BOM::User->create(
        email          => $virtual_client2->email,
        password       => "hello",
        email_verified => 1,
    );

    $user2->add_client($virtual_client2);

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);
    undef @identify_args;
    undef @track_args;
    my $vr_args = {
        loginid    => $virtual_client2->loginid,
        properties => {
            type     => 'virtual',
            utm_tags => {
                utm_source         => 'direct',
                signup_device      => 'desktop',
                date_first_contact => '2019-11-28'
            }}};
    $virtual_client2->set_default_account('USD');
    my $handler = BOM::Event::Process::get_action_mappings()->{signup};
    my $result  = $handler->($vr_args)->get;
    is $result, 1, 'Success result';

    my ($customer, %args) = @identify_args;
    is_deeply \%args,
        {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'id'
        }
        },
        'context is properly set for signup';

    ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'signup',
        properties => {
            loginid         => $virtual_client2->loginid,
            type            => 'virtual',
            currency        => $virtual_client2->currency,
            landing_company => $virtual_client2->landing_company->short,
            country         => Locale::Country::code2country($virtual_client2->residence),
            date_joined     => $virtual_client2->date_joined,
            'address'       => {
                street      => ' ',
                town        => '',
                state       => '',
                postal_code => '',
                country     => Locale::Country::code2country($virtual_client2->residence),
            },
        }
        },
        'properties is properly set for virtual account signup';
    test_segment_customer($customer, $virtual_client2, '', $virtual_client2->date_joined);

    my $test_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test2@bin.com',
    });
    my $real_args = {
        loginid    => $test_client2->loginid,
        properties => {
            type => 'real',
        }};
    $user2->add_client($test_client2);

    undef @identify_args;
    undef @track_args;

    $result = $handler->($real_args)->get;

    is $result, 1, 'Success signup result';
    ($customer, %args) = @identify_args;
    test_segment_customer($customer, $test_client2, '', $virtual_client2->date_joined);

    is_deeply \%args,
        {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'id'
        }
        },
        'identify context is properly set for signup';

    ($customer, %args) = @track_args;
    test_segment_customer($customer, $test_client2, '', $virtual_client2->date_joined);
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    my ($year, $month, $day) = split('-', $test_client2->date_of_birth);
    is_deeply \%args, {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'signup',
        properties => {
            # currency => is not set yet
            loginid         => $test_client2->loginid,
            date_joined     => $test_client2->date_joined,
            first_name      => $test_client2->first_name,
            last_name       => $test_client2->last_name,
            phone           => $test_client2->phone,
            country         => Locale::Country::code2country($test_client2->residence),
            landing_company => $test_client2->landing_company->short,
            age             => (
                Time::Moment->new(
                    year  => $year,
                    month => $month,
                    day   => $day
                )->delta_years(Time::Moment->now_utc)
            ),
            'address' => {
                street      => $test_client->address_line_1 . " " . $test_client->address_line_2,
                town        => $test_client->address_city,
                state       => BOM::Platform::Locale::get_state_by_id($test_client->state, $test_client->residence) // '',
                postal_code => $test_client->address_postcode,
                country     => Locale::Country::code2country($test_client->residence),
            },
            type => 'real',
        }
        },
        'properties is set properly for real account signup event';

    $test_client2->set_default_account('EUR');

    ok $handler->($real_args)->get, 'successful signup track after setting currency';

    ($customer, %args) = @track_args;
    test_segment_customer($customer, $test_client2, 'EUR', $virtual_client2->date_joined);

};

subtest 'account closure' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);

    undef @identify_args;
    undef @track_args;

    my $loginid = $test_client->loginid;

    $segment_response = Future->done(1);
    my $call_args = {
        closing_reason    => 'There is no reason',
        loginid           => $loginid,
        loginids_disabled => [$loginid],
        loginids_failed   => []};

    my $action_handler = BOM::Event::Process::get_action_mappings()->{account_closure};
    my $result         = $action_handler->($call_args)->get;
    is $result, 1, 'Success result';

    is scalar @identify_args, 0, 'No identify event is triggered';

    my ($customer, %args) = @track_args;
    is_deeply \%args, {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'account_closure',
        properties => {
            closing_reason    => 'There is no reason',
            loginid           => $loginid,
            loginids_disabled => [$loginid],
            loginids_failed   => [],

        },
        },
        'track context and properties are correct.';
    undef @track_args;

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);
    $result = $action_handler->($call_args)->get;
    is $result, undef, 'Empty result';
    is scalar @identify_args, 0, 'No identify event is triggered when brand is binary';
    is scalar @track_args,    0, 'No track event is triggered when brand is binary';
};

subtest 'transfer between accounts event' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);

    undef @track_args;
    undef @identify_args;

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            from_account       => $test_client->loginid,
            to_account         => 'CR000',
            from_currency      => 'USD',
            to_currency        => 'BTC',
            from_amount        => 2,
            to_amount          => 1,
            source             => '16303',
            fees               => 0.0222,
            remark             => 'test remark',
            gateway_code       => 'account_transfer',
            is_from_account_pa => 0,
            is_to_account_pa   => 0,
            id                 => 10,
            time               => '2020-01-09 10:00:00.000'
        }};

    my $action_handler = BOM::Event::Process::get_action_mappings()->{transfer_between_accounts};
    ok $action_handler->($args), 'transfer_between_accounts triggered successfully';
    my ($customer, %args) = @track_args;
    is scalar(@identify_args), 0, 'identify is not called';

    is_deeply(
        \%args,
        {
            context => {
                active => 1,
                app    => {name => "deriv"},
                locale => "id"
            },
            event      => "transfer_between_accounts",
            properties => {
                currency      => $test_client->currency,
                fees          => 0.02,
                from_account  => $test_client->loginid,
                from_amount   => 2,
                from_currency => "USD",
                gateway_code  => "account_transfer",
                remark        => "test remark",
                revenue       => -2,
                source        => 16303,
                to_account    => "CR000",
                to_amount     => 1,
                to_currency   => "BTC",
                value         => 2,
                id            => 10,
                time          => '2020-01-09T10:00:00Z'
            },
        },
        'identify context is properly set for transfer_between_account'
    );

    # Calling with `payment_agent_transfer` gateway should contain PaymentAgent fields
    $args->{properties}->{gateway_code} = 'payment_agent_transfer';

    ok $action_handler->($args), 'transfer_between_accounts triggered successfully';
    ($customer, %args) = @track_args;
    is scalar(@identify_args), 0, 'identify is not called';

    is_deeply(
        \%args,
        {
            context => {
                active => 1,
                app    => {name => "deriv"},
                locale => "id"
            },
            event      => "transfer_between_accounts",
            properties => {
                currency           => $test_client->currency,
                fees               => 0.02,
                from_account       => $test_client->loginid,
                from_amount        => 2,
                from_currency      => "USD",
                gateway_code       => "payment_agent_transfer",
                remark             => "test remark",
                revenue            => -2,
                source             => 16303,
                to_account         => "CR000",
                to_amount          => 1,
                to_currency        => "BTC",
                value              => 2,
                is_from_account_pa => 0,
                is_to_account_pa   => 0,
                id                 => 10,
                time               => '2020-01-09T10:00:00Z'
            },
        },
        'identify context is properly set for transfer_between_account'
    );
};

subtest 'api token create' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);

    undef @identify_args;
    undef @track_args;

    my $loginid = $test_client->loginid;

    $segment_response = Future->done(1);
    my $call_args = {
        loginid => $loginid,
        name    => [$loginid],
        scopes  => ['read', 'payment']};

    my $action_handler = BOM::Event::Process::get_action_mappings()->{api_token_created};
    my $result         = $action_handler->($call_args)->get;
    is $result, 1, 'Success result';

    is scalar @identify_args, 0, 'No identify event is triggered';

    my ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'api_token_created',
        properties => {
            loginid => $loginid,
            name    => [$loginid],
            scopes  => ['read', 'payment'],
        },
        },
        'track context and properties are correct.';
    undef @track_args;

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);
    $result = $action_handler->($call_args)->get;
    is $result, undef, 'Empty result (not emitted)';
    is scalar @identify_args, 0, 'No identify event is triggered when brand is binary';
    is scalar @track_args,    0, 'No track event is triggered when brand is binary';
};

subtest 'api token delete' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $loginid = $test_client->loginid;

    $segment_response = Future->done(1);
    my $call_args = {
        loginid => $loginid,
        name    => [$loginid],
        scopes  => ['read', 'payment']};

    my $action_handler = BOM::Event::Process::get_action_mappings()->{api_token_deleted};
    my $result         = $action_handler->($call_args)->get;
    is $result, 1, 'Success result';

    is scalar @identify_args, 0, 'No identify event is triggered';

    my ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'api_token_deleted',
        properties => {
            loginid => $loginid,
            name    => [$loginid],
            scopes  => ['read', 'payment'],
        },
        },
        'track context and properties are correct.';
    undef @track_args;

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);
    $result = $action_handler->($call_args)->get;
    is $result, undef, 'Empty result (not emitted)';
    is scalar @identify_args, 0, 'No identify event is triggered when brand is binary';
    is scalar @track_args,    0, 'No track event is triggered when brand is binary';
};

sub test_segment_customer {
    my ($customer, $test_client, $currencies, $created_at) = @_;

    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is $customer->user_id, $test_client->binary_user_id, 'User id is binary user id';
    if ($test_client->is_virtual) {
        is_deeply $customer->traits,
            {
            'email'      => $test_client->email,
            'first_name' => $test_client->first_name,
            'last_name'  => $test_client->last_name,
            'phone'      => $test_client->phone,
            'country'    => Locale::Country::code2country($test_client->residence),
            'created_at' => Date::Utility->new($created_at)->datetime_iso8601,
            'currencies' => $currencies,
            'address'    => {
                street      => ' ',
                town        => '',
                state       => '',
                postal_code => '',
                country     => Locale::Country::code2country($test_client->residence),
            },
            'birthday'           => undef,
            'age'                => undef,
            'signup_device'      => 'desktop',
            'utm_source'         => 'direct',
            'date_first_contact' => '2019-11-28',
            mt5_loginids         => join(',', $test_client->user->mt5_logins),
            },
            'Customer traits are set correctly for virtual account';
    } else {
        my ($year, $month, $day) = split('-', $test_client->date_of_birth);

        is_deeply $customer->traits,
            {
            'email'      => $test_client->email,
            'first_name' => $test_client->first_name,
            'last_name'  => $test_client->last_name,
            'birthday'   => $test_client->date_of_birth,
            'age'        => (
                Time::Moment->new(
                    year  => $year,
                    month => $month,
                    day   => $day
                )->delta_years(Time::Moment->now_utc)
            ),
            'phone'      => $test_client->phone,
            'created_at' => Date::Utility->new($created_at)->datetime_iso8601,
            'address'    => {
                street      => $test_client->address_line_1 . " " . $test_client->address_line_2,
                town        => $test_client->address_city,
                state       => BOM::Platform::Locale::get_state_by_id($test_client->state, $test_client->residence) // '',
                postal_code => $test_client->address_postcode,
                country     => Locale::Country::code2country($test_client->residence),
            },
            'currencies' => $currencies,
            'country'    => Locale::Country::code2country($test_client->residence),
            mt5_loginids => join(',', $test_client->user->mt5_logins),
            },
            'Customer traits are set correctly';
    }
}

subtest 'set financial assessment segment' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);

    undef @track_args;

    my $action_handler = BOM::Event::Process::get_action_mappings()->{set_financial_assessment};
    my $loginid        = $test_client->loginid;
    my $args           = {
        'params' => {
            'binary_options_trading_frequency'     => '6-10 transactions in the past 12 months',
            'net_income'                           => '$100,001 - $500,000',
            'education_level'                      => 'Primary',
            'cfd_trading_experience'               => 'Over 3 years',
            'binary_options_trading_experience'    => 'Over 3 years',
            'other_instruments_trading_experience' => '0-1 year',
            'forex_trading_experience'             => '0-1 year',
            'employment_industry'                  => 'Finance',
            'income_source'                        => 'Self-Employed',
            'occupation'                           => 'Managers',
            'account_turnover'                     => '$100,001 - $500,000',
            'cfd_trading_frequency'                => '6-10 transactions in the past 12 months',
            'employment_status'                    => 'Employed',
            'source_of_wealth'                     => 'Company Ownership',
            'estimated_worth'                      => '$500,001 - $1,000,000',
            'forex_trading_frequency'              => '11-39 transactions in the past 12 months',
            'other_instruments_trading_frequency'  => '11-39 transactions in the past 12 months'
        },
        'loginid' => $loginid,
    };

    $action_handler->($args)->get;
    my ($customer, %returned_args) = @track_args;
    is_deeply(
        {$args->{params}->%*, loginid => $loginid},
        $returned_args{properties},
        'track properties are properly set for set_financial_assessment'
    );
    is $returned_args{event}, 'set_financial_assessment', 'track event name is set correctly';
};

subtest 'segment document upload' => sub {

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);

    undef @track_args;

    $args = {
        document_type     => 'national_identity_card',
        document_format   => 'PNG',
        document_id       => '1234',
        expiration_date   => '1900-01-01',
        expected_checksum => '123456',
        page_type         => undef,
    };

    my $upload_info = $test_client->db->dbic->run(
        ping => sub {
            $_->selectrow_hashref(
                'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?)', undef,
                $test_client->loginid,                                                      $args->{document_type},
                $args->{document_format}, $args->{expiration_date} || undef,
                $args->{document_id} || '', $args->{expected_checksum},
                '', $args->{page_type} || '',
            );
        });

    $test_client->db->dbic->run(
        ping => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
        });

    undef @track_args;
    my $action_handler = BOM::Event::Process::get_action_mappings()->{document_upload};
    $action_handler->({
            loginid => $test_client->loginid,
            file_id => $upload_info->{file_id}})->get;

    my ($customer, %args) = @track_args;

    is $args{event}, 'document_upload', 'track event is document_upload';
    is $args{properties}->{document_type}, 'national_identity_card', 'document type is correct';
    is $args{properties}->{uploaded_manually_by_staff}, 0, 'uploaded_manually_by_staff is correct';
};

subtest 'aml risk becomes high withdrawal_locked email CR landing company' => sub {
    mailbox_clear();
    my $landing_company = 'CR';
    my $aml_high_clients = [{login_ids => $test_client->loginid}];
    #send email
    BOM::Event::Actions::Client::aml_client_status_update({
            template_args => {
                landing_company     => $landing_company,
                aml_updated_clients => @$aml_high_clients
            }});
    my $subject = 'High risk status reached - pending KYC-FA - withdrawal locked accounts';
    my $msg     = mailbox_search(
        email   => 'compliance-alerts@binary.com',
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");
};

subtest 'onfido resubmission' => sub {
    # Redis key for resubmission counter
    use constant ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX => 'ONFIDO::RESUBMISSION_COUNTER::ID::';
    # Redis key for resubmission flag
    use constant ONFIDO_ALLOW_RESUBMISSION_KEY_PREFIX => 'ONFIDO::ALLOW_RESUBMISSION::ID::';
    # Redis key for daily onfido submission per user
    use constant ONFIDO_REQUEST_PER_USER_PREFIX => 'ONFIDO::DAILY::REQUEST::PER::USER::';

    # These keys blocks email sending on client verification failure
    use constant ONFIDO_AGE_EMAIL_PER_USER_PREFIX                => 'ONFIDO::AGE::VERIFICATION::EMAIL::PER::USER::';
    use constant ONFIDO_DOB_MISMATCH_EMAIL_PER_USER_PREFIX       => 'ONFIDO::DOB::MISMATCH::EMAIL::PER::USER::';
    use constant ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX => 'ONFIDO::AGE::BELOW::EIGHTEEN::EMAIL::PER::USER::';
    use constant ONFIDO_POI_EMAIL_NOTIFICATION_SENT_PREFIX       => 'ONFIDO::POI::EMAIL::NOTIFICATION::SENT::';
    # This key gives resubmission context to onfido webhook event
    use constant ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX => 'ONFIDO::IS_A_RESUBMISSION::ID::';

    # Global counters
    use constant ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY => 'ONFIDO_AUTHENTICATION_REQUEST_CHECK';
    use constant ONFIDO_REQUEST_COUNT_KEY               => 'ONFIDO_REQUEST_COUNT';
    $loop->add($services = BOM::Event::Services->new);
    my $redis_write  = $services->redis_replicated_write();
    my $redis_events = $services->redis_events_write();
    $redis_write->connect->get;
    $redis_events->connect->get;

    # Mock stuff
    my $mock_client = Test::MockModule->new('BOM::Event::Actions::Client');
    $mock_client->mock(
        '_check_applicant',
        sub {
            Future->done;
        });

    # First test, we expect counter to be +1
    $redis_write->set(ONFIDO_ALLOW_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id, 1)->get;
    my $counter = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get // 0;
    my $call_args = {
        loginid      => $test_client->loginid,
        applicant_id => $applicant_id
    };
    my $action_handler = BOM::Event::Process::get_action_mappings()->{ready_for_authentication};
    $redis_events->set(ONFIDO_AGE_EMAIL_PER_USER_PREFIX . $test_client->binary_user_id,                1)->get;
    $redis_events->set(ONFIDO_DOB_MISMATCH_EMAIL_PER_USER_PREFIX . $test_client->binary_user_id,       1)->get;
    $redis_events->set(ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $test_client->binary_user_id, 1)->get;
    $redis_events->set(ONFIDO_POI_EMAIL_NOTIFICATION_SENT_PREFIX . $test_client->binary_user_id,       1)->get;
    $redis_write->del(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id)->get;
    $action_handler->($call_args)->get;
    my $counter_after = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    my $ttl           = $redis_write->ttl(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter + 1, $counter_after, 'Resubmission Counter has been incremented by 1');

    my $age_email_per_user          = $redis_events->get(ONFIDO_AGE_EMAIL_PER_USER_PREFIX . $test_client->binary_user_id)->get;
    my $dob_mismatch_email_per_user = $redis_events->get(ONFIDO_DOB_MISMATCH_EMAIL_PER_USER_PREFIX . $test_client->binary_user_id)->get;
    my $age_below_eighteen_per_user = $redis_events->get(ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $test_client->binary_user_id)->get;
    my $poi_email_sent              = $redis_events->get(ONFIDO_POI_EMAIL_NOTIFICATION_SENT_PREFIX . $test_client->binary_user_id)->get;
    ok(!$age_email_per_user,          'Email blocker is gone');
    ok(!$dob_mismatch_email_per_user, 'Email blocker is gone');
    ok(!$age_below_eighteen_per_user, 'Email blocker is gone');
    ok(!$poi_email_sent,              'Email blocker is gone');

    my $resubmission_context = $redis_write->get(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id)->get;
    ok($resubmission_context, 'Resubmission Context is set');

    # Resubmission flag should be off now and so we expect counter to remain the same
    $action_handler->($call_args)->get;
    my $counter_after2 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter_after, $counter_after2, 'Resubmission Counter has not been incremented');

    # TTL should be the same after running it twice (roughly 30 days)
    # We, firstly, set a lower expire time
    $redis_write->expire(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id, 100)->get;
    my $lower_ttl = $redis_write->ttl(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($lower_ttl, 100, 'Resubmission Counter TTL has been set to 100');
    # Activate the flag and run again
    $redis_write->set(ONFIDO_ALLOW_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id, 1)->get;
    $action_handler->($call_args)->get;
    # After running it twice TTL should be set to full time again (roughly 30 days, whatever $ttl is)
    my $ttl2 = $redis_write->ttl(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($ttl, $ttl2, 'Resubmission Counter TTL has been reset to its full time again');

    # For this one user's onfido daily counter will be too high, so the checkup won't be made
    my $counter_after3 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    $redis_events->set(ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id, $ENV{ONFIDO_REQUEST_PER_USER_LIMIT} // 3)->get;
    $redis_write->set(ONFIDO_ALLOW_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id, 1)->get;
    $action_handler->($call_args)->get;
    my $counter_after4 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter_after3, $counter_after4, 'Resubmission Counter has not been incremented due to user limits');

    # The last one, will be made upon the fact the whole company has its own onfido submit limit
    $redis_events->hset(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY, $ENV{ONFIDO_REQUESTS_LIMIT} // 1000)->get;
    $redis_events->set(ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id, 0)->get;
    $redis_write->set(ONFIDO_ALLOW_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id, 1)->get;
    $action_handler->($call_args)->get;
    my $counter_after5 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter_after4, $counter_after5, 'Resubmission Counter has not been incremented due to global limits');
    $redis_events->hset(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY, 0)->get;
    $redis_events->set(ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id, 0)->get;

    subtest "client_verification on resubmission, verification failed" => sub {
        mailbox_clear();

        lives_ok {
            BOM::Event::Actions::Client::client_verification({
                    check_url => $check->{href},
                })->get;
        }
        "client verification no exception";

        my $msg = mailbox_search(subject => qr/Automated age verification failed/);
        ok($msg, 'automated age verification failed email sent');

        my $resubmission_context = $redis_write->get(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id)->get // 0;
        is($resubmission_context, 0, 'Resubmission Context is deleted');
    };

    subtest "client_verification on resubmission, verification success" => sub {
        # As I don't have/know a valid payload from onfido, I'm going to test _update_client_status instead
        mailbox_clear();

        BOM::Event::Actions::Client::_update_client_status(
            client       => $test_client,
            status       => 'age_verification',
            message      => 'Onfido - age verified',
            resubmission => 1
        );

        my $msg = mailbox_search(subject => qr/Resubmitted POI document for: (.*) is verified/);
        ok($msg, 'Valid email sent for resubmission');
    };

    $mock_client->unmock_all;
};

subtest 'client becomes transfers_blocked when deposits from QIWI' => sub {
    ok !$test_client->status->transfers_blocked, 'client is not transfers_blocked before deposit from QIWI';

    BOM::Event::Actions::Client::payment_deposit({
        loginid           => $test_client->loginid,
        is_first_deposit  => 0,
        payment_processor => 'Qiwi',
    });

    $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
    ok $test_client->status->transfers_blocked, 'transfers_blocked status is set correctly after deposit from QIWI';
};

done_testing();
