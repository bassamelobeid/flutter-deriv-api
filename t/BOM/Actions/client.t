use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Fatal;
use Test::Deep;
use Guard;
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

use WebService::Async::SmartyStreets::Address;
use Encode qw(encode_utf8);
use Locale::Codes::Country qw(country_code2code);

my $brand = Brands->new(name => 'deriv');
my ($app_id) = $brand->whitelist_apps->%*;
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

my @emit_args;
my $mock_emitter = new Test::MockModule('BOM::Platform::Event::Emitter');
$mock_emitter->mock('emit', sub { push @emit_args, @_ });

my @enabled_brands = ('deriv', 'binary');
my $mock_brands    = Test::MockModule->new('Brands');
$mock_brands->mock(
    'is_track_enabled' => sub {
        my $self = shift;
        return (grep { $_ eq $self->name } @enabled_brands);
    });

my $onfido_doc = Test::MockModule->new('WebService::Async::Onfido::Document');
$onfido_doc->mock('side', sub { return undef });

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->set_default_account('USD');

my $test_sibling = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_sibling->set_default_account('LTC');

my $test_user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);
$test_user->add_client($test_client);
$test_user->add_client($test_sibling);
$test_client->place_of_birth('cn');
$test_client->binary_user_id($test_user->id);
$test_client->save;
$test_sibling->binary_user_id($test_user->id);
$test_sibling->save;

mailbox_clear();

BOM::Event::Actions::Client::_email_client_age_verified($test_client);

my $msg = mailbox_search(subject => qr/Your identity is verified/);

is($msg->{from}, 'no-reply@deriv.com', 'Correct from Address');
$test_client->status->set('age_verification');

mailbox_clear();
BOM::Event::Actions::Client::_email_client_age_verified($test_client);

$msg = mailbox_search(subject => qr/Your identity is verified/);
is($msg, undef, "Didn't send email when already age verified");

mailbox_clear();

my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
});

BOM::Event::Actions::Client::_email_client_age_verified($test_client_mx);

$msg = mailbox_search(subject => qr/Your identity is verified/);
is($msg, undef, 'No email for non CR account');

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
BOM::Event::Actions::Client::email_client_account_verification({loginid => $test_client_cr->loginid});

$msg = mailbox_search(subject => qr/Your address and identity have been verified successfully/);

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
    $loop->add(my $services = BOM::Event::Services->new);
    $test_client->status->set('allow_poa_resubmission', 'test', 'test');
    $test_client->copy_status_to_siblings('allow_poa_resubmission', 'test');
    ok $test_sibling->status->_get('allow_poa_resubmission'), 'POA flag propagated to siblings';

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

    subtest "invalid place_of_birth" => sub {
        my $old_pob = $test_client->place_of_birth;
        scope_guard {
            $test_client->place_of_birth($old_pob);
            $test_client->save;
        };
        $test_client->place_of_birth('xxx');
        $test_client->save;
        $log->clear;
        BOM::Event::Actions::Client::document_upload({
                loginid => $test_client->loginid,
                file_id => $upload_info->{file_id}})->get;
        $log->contains_ok(qr/Document not uploaded to Onfido as client is from list of countries not supported by Onfido/,
            'error log: country not supported');
    };

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

    my $resubmission_flag_after = $test_client->status->_get('allow_poa_resubmission');
    ok !$resubmission_flag_after, 'poa resubmission status is removed after document uploading';

    my $sibling_resubmission_flag_after = $test_sibling->status->_get('allow_poa_resubmission');
    ok !$sibling_resubmission_flag_after, 'poa resubmission status is removed from the sibling after document uploading';

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
    my $ryu_mock      = Test::MockModule->new('Ryu::Source');
    my $onfido_mocker = Test::MockModule->new('WebService::Async::Onfido');

    $onfido_mocker->mock(
        'photo_list',
        sub {
            return Ryu::Source->new;
        });

    $ryu_mock->mock(
        'as_list',
        sub {
            return Future->done(1, 2, 3);
        });
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
    $onfido_mocker->unmock_all;
    $ryu_mock->unmock_all;
};

my $services;
subtest "client_verification" => sub {
    $loop->add($services = BOM::Event::Services->new);
    my $redis_write = $services->redis_events_write();
    $redis_write->connect->get;
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
};

subtest "Uninitialized date of birth" => sub {

    my $mocked_report =
        Test::MockModule->new('WebService::Async::Onfido::Report');    #TODO Refactor mock_onfido.pl inorder to return report with initialized dob
    $mocked_report->mock(
        'new' => sub {
            my $self = shift, my %data = @_;
            $data{properties}->{date_of_birth} = '2003-01-01';
            $mocked_report->original('new')->($self, %data);
        });

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    $mocked_client->mock(date_of_birth => sub { return undef; });

    lives_ok {
        BOM::Event::Actions::Client::client_verification({
                check_url => $check->{href},
            })->get;
    }
    "client verification should pass with undef dob";

    $mocked_client->unmock_all();
    $mocked_report->unmock_all();
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
    $mocked_action->mock('_store_applicant_documents', sub { $request = request(); return Future->done; });

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
                undef,             $applicant2->id, Date::Utility->new($applicant2->created_at)->datetime_yyyymmdd_hhmmss,
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
        BOM::Event::Actions::Client::onfido_doc_ready_for_upload({
                type           => 'photo',
                document_id    => $doc->id,
                client_loginid => $test_client2->loginid,
                applicant_id   => $applicant_id2,
                file_type      => $doc->file_type,
            })->get;
    }
    "ready_for_authentication no exception";

    my $clientdb      = BOM::Database::ClientDB->new({broker_code => 'CR'});
    my $doc_file_name = $clientdb->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare('select file_name from betonmarkets.client_authentication_document where client_loginid=? and document_type=?');
            $sth->execute($test_client2->loginid, 'photo');
            return $sth->fetchall_arrayref({})->[0]{file_name};
        });

    like($doc_file_name, qr{\.png$}, 'uploaded document has expected png extension');

    my $mocked_user_onfido = Test::MockModule->new('BOM::User::Onfido');
    # simulate the case that 2 processes uploading same documents almost at same time.
    # at first process 1 doesn't upload document yet, so process 2 get_onfido_live_photo will return null
    # and when process 2 call db func `start_document_upload` , process 1 already uploaded file.
    # at this time process 2 should report a warn.
    $mocked_user_onfido->mock(get_onfido_live_photo   => sub { diag "in mocked get_";  return undef });
    $mocked_user_onfido->mock(store_onfido_live_photo => sub { diag "in mocked store"; return undef });

    lives_ok {
        BOM::Event::Actions::Client::onfido_doc_ready_for_upload({
                type           => 'photo',
                document_id    => $doc->id,
                client_loginid => $test_client2->loginid,
                applicant_id   => $applicant_id2,
                file_type      => $doc->file_type,
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
        email_consent  => 1,
    );

    $user2->add_client($virtual_client2);

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;
    undef @emit_args;
    my $vr_args = {
        loginid    => $virtual_client2->loginid,
        properties => {
            type     => 'trading',
            subtype  => 'virtual',
            utm_tags => {
                utm_source         => 'direct',
                signup_device      => 'desktop',
                utm_content        => 'synthetic-ebook',
                utm_term           => 'term',
                date_first_contact => '2019-11-28'
            }}};
    $virtual_client2->set_default_account('USD');
    my $handler = BOM::Event::Process::get_action_mappings()->{signup};
    my $result  = $handler->($vr_args)->get;
    ok $result, 'Success result';

    my ($customer, %args) = @identify_args;
    is_deeply \%args,
        {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'ID'
        }
        },
        'context is properly set for signup';
    ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'ID'
        },
        event      => 'signup',
        properties => {
            loginid         => $virtual_client2->loginid,
            type            => 'trading',
            subtype         => 'virtual',
            currency        => $virtual_client2->currency,
            landing_company => $virtual_client2->landing_company->short,
            country         => Locale::Country::code2country($virtual_client2->residence),
            date_joined     => $virtual_client2->date_joined,
            provider        => 'email',
            address         => {
                street      => ' ',
                town        => '',
                state       => '',
                postal_code => '',
                country     => Locale::Country::code2country($virtual_client2->residence),
            },
            brand         => 'deriv',
            email_consent => 1,
        }
        },
        'properties is properly set for virtual account signup';
    test_segment_customer($customer, $virtual_client2, '', $virtual_client2->date_joined, 'virtual', 'labuan,svg');

    is_deeply \@emit_args, ['new_crypto_address', {loginid => $virtual_client2->loginid}], 'new_crypto_address event is emitted';

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
    undef @emit_args;

    $result = $handler->($real_args)->get;

    ok $result, 'Success signup result';
    ($customer, %args) = @identify_args;
    test_segment_customer($customer, $test_client2, '', $virtual_client2->date_joined, 'svg', 'labuan,svg');

    is_deeply \%args,
        {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'ID'
        }
        },
        'identify context is properly set for signup';

    ($customer, %args) = @track_args;
    test_segment_customer($customer, $test_client2, '', $virtual_client2->date_joined, 'svg', 'labuan,svg');
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    my ($year, $month, $day) = split('-', $test_client2->date_of_birth);
    is_deeply \%args, {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'ID'
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
            type          => 'real',
            provider      => 'email',
            brand         => 'deriv',
            email_consent => 1,
        }
        },
        'properties is set properly for real account signup event';

    is_deeply \@emit_args,
        [
        'new_crypto_address',
        {loginid => $test_client2->loginid},
        'verify_false_profile_info',
        {
            loginid    => $test_client2->loginid,
            first_name => $test_client2->first_name,
            last_name  => $test_client2->last_name,
        }
        ],
        'new_crypto_address and verify_false_profile_info events are emitted';

    $test_client2->set_default_account('EUR');

    ok $handler->($real_args)->get, 'successful signup track after setting currency';

    ($customer, %args) = @track_args;
    test_segment_customer($customer, $test_client2, 'EUR', $virtual_client2->date_joined, 'svg', 'labuan,svg');
};

subtest 'wallet signup event' => sub {
    my $virtual_wallet_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code      => 'VRDW',
        email            => 'virtual_wallet@binary.com',
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
    my $email = $virtual_wallet_client->email;

    my $user = BOM::User->create(
        email          => $virtual_wallet_client->email,
        password       => "hello",
        email_verified => 1,
        email_consent  => 1,
    );

    $user->add_client($virtual_wallet_client);

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;
    my $vr_args = {
        loginid    => $virtual_wallet_client->loginid,
        properties => {
            type     => 'wallet',
            subtype  => 'virtual',
            utm_tags => {
                utm_source         => 'direct',
                signup_device      => 'desktop',
                utm_content        => 'synthetic-ebook',
                utm_term           => 'term',
                date_first_contact => '2019-11-28'
            }}};
    $virtual_wallet_client->set_default_account('USD');
    my $handler = BOM::Event::Process::get_action_mappings()->{signup};
    my $result  = $handler->($vr_args)->get;
    ok $result, 'Success result';

    my ($customer, %args) = @identify_args;
    is_deeply \%args,
        {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'ID'
        }
        },
        'context is properly set for signup';

    ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'ID'
        },
        event      => 'signup',
        properties => {
            loginid         => $virtual_wallet_client->loginid,
            type            => 'wallet',
            subtype         => 'virtual',
            currency        => $virtual_wallet_client->currency,
            landing_company => $virtual_wallet_client->landing_company->short,
            country         => Locale::Country::code2country($virtual_wallet_client->residence),
            date_joined     => $virtual_wallet_client->date_joined,
            provider        => 'email',
            address         => {
                street      => ' ',
                town        => '',
                state       => '',
                postal_code => '',
                country     => Locale::Country::code2country($virtual_wallet_client->residence),
            },
            brand         => 'deriv',
            email_consent => 1,
        }
        },
        'properties is properly set for wallet virtual account signup';
    test_segment_customer($customer, $virtual_wallet_client, '', $virtual_wallet_client->date_joined, 'virtual', 'labuan,svg');
};

subtest 'account closure' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    my $email_args;
    my $mock_client = Test::MockModule->new('BOM::Event::Actions::Client');
    $mock_client->redefine('send_email', sub { $email_args = shift; });

    undef @identify_args;
    undef @track_args;
    undef $email_args;

    my $loginid = $test_client->loginid;

    $segment_response = Future->done(1);
    my $call_args = {
        closing_reason    => 'There is no reason',
        loginid           => $loginid,
        loginids_disabled => [$loginid],
        loginids_failed   => [],
        email_consent     => 0
    };

    my $action_handler = BOM::Event::Process::get_action_mappings()->{account_closure};
    my $result         = $action_handler->($call_args)->get;
    ok $result, 'Success result';

    ok @identify_args, 'Identify event is triggered';

    my ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'EN'
        },
        event      => 'account_closure',
        properties => {
            closing_reason    => 'There is no reason',
            loginid           => $loginid,
            loginids_disabled => [$loginid],
            loginids_failed   => [],
            email_consent     => 0,
            brand             => 'deriv',
        },
        },
        'track context and properties are correct.';

    is_deeply $email_args,
        {
        'to'                    => $test_client->email,
        'subject'               => 'Your accounts are deactivated',
        'template_name'         => 'account_closure',
        'email_content_is_html' => 1,
        'use_email_template'    => 1,
        'use_event'             => 1
        },
        'correct email is sent';

    undef @identify_args;
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

    $mock_client->unmock_all;
};

subtest 'transfer between accounts event' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
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
                locale => "ID"
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
                time          => '2020-01-09T10:00:00Z',
                brand         => 'deriv',
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
                locale => "ID"
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
                time               => '2020-01-09T10:00:00Z',
                brand              => 'deriv',
            },
        },
        'identify context is properly set for transfer_between_account'
    );
};

subtest 'api token create' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
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
    ok $result, 'Success result';

    is scalar @identify_args, 0, 'No identify event is triggered';

    my ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'ID'
        },
        event      => 'api_token_created',
        properties => {
            brand   => 'deriv',
            loginid => $loginid,
            name    => [$loginid],
            scopes  => ['read', 'payment'],
        },
        },
        'track context and properties are correct.';
    undef @track_args;

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'ID'
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
        language   => 'ID',
        app_id     => $app_id,
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
    ok $result, 'Success result';

    is scalar @identify_args, 0, 'No identify event is triggered';

    my ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'ID'
        },
        event      => 'api_token_deleted',
        properties => {
            loginid => $loginid,
            name    => [$loginid],
            scopes  => ['read', 'payment'],
            brand   => 'deriv',
        },
        },
        'track context and properties are correct.';
    undef @track_args;

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'ID'
    );
    request($req);
    $result = $action_handler->($call_args)->get;
    is $result, undef, 'Empty result (not emitted)';
    is scalar @identify_args, 0, 'No identify event is triggered when brand is binary';
    is scalar @track_args,    0, 'No track event is triggered when brand is binary';
};

sub test_segment_customer {
    my ($customer, $test_client, $currencies, $created_at, $landing_companies, $available_landing_companies) = @_;

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
            'birthday'                  => undef,
            'age'                       => undef,
            'signup_device'             => 'desktop',
            'utm_source'                => 'direct',
            'utm_content'               => 'synthetic-ebook',
            'utm_term'                  => 'term',
            'date_first_contact'        => '2019-11-28',
            mt5_loginids                => join(',', $test_client->user->mt5_logins),
            landing_companies           => $landing_companies,
            available_landing_companies => $available_landing_companies,
            provider                    => 'email',
            unsubscribed                => $test_client->user->email_consent ? 'false' : 'true',
            signup_brand                => 'deriv',
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
            'currencies'                => $currencies,
            'country'                   => Locale::Country::code2country($test_client->residence),
            mt5_loginids                => join(',', $test_client->user->mt5_logins),
            landing_companies           => $landing_companies,
            available_landing_companies => $available_landing_companies,
            provider                    => 'email',
            unsubscribed                => $test_client->user->email_consent ? 'false' : 'true',
            signup_brand                => 'deriv',
            },
            'Customer traits are set correctly';
    }
}

subtest 'set financial assessment segment' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
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
    is_deeply({
            $args->{params}->%*,
            loginid => $loginid,
            brand   => 'deriv'
        },
        $returned_args{properties},
        'track properties are properly set for set_financial_assessment'
    );
    is $returned_args{event}, 'set_financial_assessment', 'track event name is set correctly';
};

subtest 'segment document upload' => sub {

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
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
    is $args{properties}->{document_type},              'national_identity_card', 'document type is correct';
    is $args{properties}->{uploaded_manually_by_staff}, 0,                        'uploaded_manually_by_staff is correct';
};

subtest 'aml risk becomes high withdrawal_locked email CR landing company' => sub {
    mailbox_clear();
    my $landing_company  = 'CR';
    my $aml_high_clients = [{login_ids => $test_client->loginid}];
    #send email
    BOM::Event::Actions::Client::aml_client_status_update({
            template_args => {
                landing_company     => $landing_company,
                aml_updated_clients => @$aml_high_clients
            }});
    my $subject = 'High risk status reached - pending KYC-FA - withdrawal locked accounts';
    my $msg     = mailbox_search(
        email   => 'compliance-alerts@deriv.com',
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");
};

subtest 'onfido resubmission' => sub {
    # Redis key for resubmission counter
    use constant ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX => 'ONFIDO::RESUBMISSION_COUNTER::ID::';
    # Redis key for daily onfido submission per user
    use constant ONFIDO_REQUEST_PER_USER_PREFIX => 'ONFIDO::REQUEST::PER::USER::';

    # These keys blocks email sending on client verification failure
    use constant ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX => 'ONFIDO::AGE::BELOW::EIGHTEEN::EMAIL::PER::USER::';
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
    $test_client->status->set('allow_poi_resubmission', 'test staff', 'reason');
    $test_client->copy_status_to_siblings('allow_poi_resubmission', 'test');
    ok $test_sibling->status->_get('allow_poi_resubmission'), 'POI flag propagated to siblings';

    # Resubmission shouldnt kick in if no previous onfido checks
    my $mock_onfido = Test::MockModule->new('BOM::User::Onfido');
    $mock_onfido->mock(
        'get_latest_onfido_check',
        sub {
            return;
        });

    # Check TTL here
    my $mock_redis = Test::MockModule->new(ref($redis_events));
    $mock_redis->mock(
        'expire',
        sub {
            my (undef, $key, $expire) = @_;

            is($expire, BOM::User::Onfido::timeout_per_user, 'Timeout correctly set for request counter per user')
                if $key =~ /ONFIDO::REQUEST::PER::USER::/;

            return $mock_redis->original('expire')->(@_);
        });

    my $action_handler = BOM::Event::Process::get_action_mappings()->{ready_for_authentication};

    # For this test, we expect counter to be 0 due to empty checks
    $redis_write->set(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id, 0)->get;
    my $counter   = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get // 0;
    my $call_args = {
        loginid      => $test_client->loginid,
        applicant_id => $applicant_id
    };

    # For this test, we expect counter to be 0 due to empty checks
    $action_handler->($call_args)->get;

    my $counter_after = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get // 0;
    is $counter, $counter_after, 'Resubmission discarded due to being the first check';

    # Check POI flag
    ok !$test_client->status->_get('allow_poi_resubmission'),  'POI flag removed from client';
    ok !$test_sibling->status->_get('allow_poi_resubmission'), 'POI flag removed from sibling';

    # Not the first check anymore
    $mock_onfido->mock(
        'get_latest_onfido_check',
        sub {
            return ({
                'status'       => 'in_progress',
                'stamp'        => '2020-10-01 16:09:35.785807',
                'href'         => '/v2/applicants/7FC678E6-0400-11EB-98D4-92B97BD2E76D/checks/7FEEF47E-0400-11EB-98D4-92B97BD2E76D',
                'api_type'     => 'express',
                'id'           => '7FEEF47E-0400-11EB-98D4-92B97BD2E76D',
                'download_uri' => 'https://onfido.com/dashboard/pdf/information_requests/<REQUEST_ID>',
                'result'       => 'clear',
                'applicant_id' => '7FC678E6-0400-11EB-98D4-92B97BD2E76D',
                'tags'         => ['automated', 'CR', 'CR10000', 'IDN'],
                'results_uri'  => 'https://onfido.com/dashboard/information_requests/<REQUEST_ID>',
                'created_at'   => '2020-10-01 16:09:35'
            });
        });

    # Then, we expect counter to be +1
    $test_client->status->set('allow_poi_resubmission', 'test staff', 'reason');
    $counter   = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get // 0;
    $call_args = {
        loginid      => $test_client->loginid,
        applicant_id => $applicant_id
    };
    $redis_events->set(ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $test_client->binary_user_id, 1)->get;
    $redis_write->del(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id)->get;
    $action_handler->($call_args)->get;
    $counter_after = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    my $ttl = $redis_write->ttl(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter + 1, $counter_after, 'Resubmission Counter has been incremented by 1');

    my $age_below_eighteen_per_user = $redis_events->get(ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $test_client->binary_user_id)->get;
    ok(!$age_below_eighteen_per_user, 'Email blocker is gone');

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
    $test_client->status->set('allow_poi_resubmission', 'test staff', 'reason');
    $action_handler->($call_args)->get;
    # After running it twice TTL should be set to full time again (roughly 30 days, whatever $ttl is)
    my $ttl2 = $redis_write->ttl(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($ttl, $ttl2, 'Resubmission Counter TTL has been reset to its full time again');

    # For this one user's onfido daily counter will be too high, so the checkup won't be made
    my $counter_after3 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    $redis_events->set(ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id, $ENV{ONFIDO_REQUEST_PER_USER_LIMIT} // 3)->get;
    $test_client->status->set('allow_poi_resubmission', 'test staff', 'reason');
    $action_handler->($call_args)->get;
    my $counter_after4 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter_after3, $counter_after4, 'Resubmission Counter has not been incremented due to user limits');

    # The last one, will be made upon the fact the whole company has its own onfido submit limit
    $redis_events->hset(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY, $ENV{ONFIDO_REQUESTS_LIMIT} // 1000)->get;
    $redis_events->set(ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id, 0)->get;
    $test_client->status->set('allow_poi_resubmission', 'test staff', 'reason');
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

        my $resubmission_context = $redis_write->get(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id)->get // 0;
        is($resubmission_context, 0, 'Resubmission Context is deleted');
    };

    subtest "_set_age_verification on resubmission, verification success" => sub {
        # As I don't have/know a valid payload from onfido, I'm going to test _set_age_verification instead
        mailbox_clear();

        my $req = BOM::Platform::Context::Request->new(language => 'EN');
        request($req);

        $test_client->status->setnx('poi_name_mismatch', 'test', 'test');
        BOM::Event::Actions::Client::_set_age_verification($test_client);
        ok !$test_client->status->age_verification, 'Could not set age verification: poi name mismatch';

        $test_client->status->clear_poi_name_mismatch;
        BOM::Event::Actions::Client::_set_age_verification($test_client);
        my $msg = mailbox_search(subject => qr/Your identity is verified/);
        ok $test_client->status->age_verification, 'Client is age verified';
        ok($msg, 'Valid email sent to client for resubmission passed');
    };

    $mock_client->unmock_all;
    $mock_onfido->unmock_all;
    $mock_redis->unmock_all;
};

subtest 'client becomes transfers_blocked when deposits from QIWI' => sub {
    ok !$test_client->status->transfers_blocked, 'client is not transfers_blocked before QIWI deposit';

    my $sibling = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $test_user->add_client($sibling);
    ok !$sibling->status->transfers_blocked, 'sibling account is not transfers_blocked before QIWI deposit';

    BOM::Event::Actions::Client::payment_deposit({
        loginid           => $test_client->loginid,
        is_first_deposit  => 0,
        payment_processor => 'Qiwi',
    });

    $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
    $sibling     = BOM::User::Client->new({loginid => $sibling->loginid});
    ok $test_client->status->transfers_blocked, 'transfers_blocked status is set correctly after QIWI deposit';
    ok $sibling->status->transfers_blocked,     'transfers_blocked status is copied over all siblings after QIWI deposit';
};

subtest 'card deposits' => sub {
    ok !$test_client->status->personal_details_locked, 'personal details are not locked';

    my $event_args = {
        loginid           => $test_client->loginid,
        is_first_deposit  => 0,
        payment_processor => 'test processor',
        transaction_id    => 123,
        payment_id        => 456,
    };

    BOM::Event::Actions::Client::payment_deposit($event_args);

    $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
    ok !$test_client->status->personal_details_locked, 'personal details are not locked - non-card payment method was used';

    for my $processor (BOM::Config::Runtime->instance->app_config->payments->credit_card_processors->@*) {
        $event_args->{payment_processor} = $processor;
        BOM::Event::Actions::Client::payment_deposit($event_args);
        $test_client = BOM::User::Client->new({loginid => $test_client->loginid});

        ok $test_client->status->personal_details_locked, 'personal details are locked when a card payment method is used';
        is $test_client->status->personal_details_locked->{reason}, "A card deposit is made via $processor with ref. id: 123";
        $test_client->status->clear_personal_details_locked;
        $test_client->save;
    }
};

subtest 'POI flag removal' => sub {
    my $document_types = [
        map {
            +{
                document_type     => $_,
                document_format   => 'PNG',
                document_id       => undef,
                expiration_date   => undef,
                expected_checksum => '12345_' . $_,
                page_type         => undef,
            }
        } qw/passport national_identity_card driving_licence proofid driverslicense/
    ];

    $test_client->status->clear_allow_poi_resubmission;
    $test_client->status->clear_allow_poa_resubmission;

    foreach my $args ($document_types->@*) {
        subtest $args->{document_type} => sub {
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

            $test_client->status->set('allow_poi_resubmission', 'test', 'test');
            $test_client->status->setnx('allow_poa_resubmission', 'test', 'test');
            $test_client->db->dbic->run(
                ping => sub {
                    $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
                });

            my $action_handler = BOM::Event::Process::get_action_mappings()->{document_upload};
            $action_handler->({
                    loginid => $test_client->loginid,
                    file_id => $upload_info->{file_id}})->get;

            ok !$test_client->status->_get('allow_poi_resubmission'), 'POI flag successfully gone';
            ok $test_client->status->_get('allow_poa_resubmission'), 'POI upload should not disable the POA flag';
        };
    }
};

subtest 'POA flag removal' => sub {
    my $document_types = [
        map {
            +{
                document_type     => $_,
                document_format   => 'PNG',
                document_id       => undef,
                expiration_date   => undef,
                expected_checksum => '12345_' . $_,
                page_type         => undef,
            }
        } qw/vf_poa proofaddress utility_bill bankstatement bank_statement cardstatement/
    ];

    $test_client->status->clear_allow_poi_resubmission;
    $test_client->status->clear_allow_poa_resubmission;

    foreach my $args ($document_types->@*) {
        subtest $args->{document_type} => sub {
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

            $test_client->status->setnx('allow_poi_resubmission', 'test', 'test');
            $test_client->status->set('allow_poa_resubmission', 'test', 'test');
            $test_client->db->dbic->run(
                ping => sub {
                    $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
                });

            my $action_handler = BOM::Event::Process::get_action_mappings()->{document_upload};
            $action_handler->({
                    loginid => $test_client->loginid,
                    file_id => $upload_info->{file_id}})->get;

            ok $test_client->status->_get('allow_poi_resubmission'), 'POA upload should not disable the POI flag';
            ok !$test_client->status->_get('allow_poa_resubmission'), 'POA flag successfully gone';
        };
    }
};

subtest 'Overwrite Experian reason' => sub {
    # Set the Experian state
    $test_client->status->upsert('age_verification',  'test', 'Experian results are sufficient to mark client as age verified.');
    $test_client->status->upsert('proveid_requested', 'test', 'ProveID request has been made for this account.');

    my $status_mock = Test::MockModule->new(ref($test_client->status));
    my $upsert_called;

    $status_mock->mock(
        'upsert',
        sub {
            $upsert_called = 1;
            return $status_mock->original('upsert')->(@_);
        });

    # Overwrite the Experian reason
    BOM::Event::Actions::Client::_set_age_verification($test_client);

    ok $upsert_called, 'Upsert was called';
    cmp_deeply $test_client->status->_get('age_verification'),
        {
        reason             => 'Onfido - age verified',
        staff_name         => 'system',
        status_code        => 'age_verification',
        last_modified_date => re('.*'),
        },
        'The Experian reason was overwritten by system';

    # If the status does not have the Experian reason, don't overwrite it
    $upsert_called = 0;
    BOM::Event::Actions::Client::_set_age_verification($test_client);

    ok !$upsert_called, 'Upsert was not called';
    cmp_deeply $test_client->status->_get('age_verification'),
        {
        reason             => 'Onfido - age verified',
        staff_name         => 'system',
        status_code        => 'age_verification',
        last_modified_date => re('.*'),
        },
        'The Experian reason was not overwritten this time';
};

subtest 'account_reactivated' => sub {
    my @email_args;
    my $mock_event = Test::MockModule->new('BOM::Event::Actions::Client');
    $mock_event->redefine('send_email', sub { push @email_args, shift; });

    my $needs_verification = 0;
    my $mock_client        = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine('needs_poi_verification', sub { return $needs_verification; });

    my $social_responsibility = 0;
    my $mock_landing_company  = Test::MockModule->new('LandingCompany');
    $mock_landing_company->redefine('social_responsibility_check_required', sub { return $social_responsibility; });

    my $call_args = {
        loginid => $test_client->loginid,
        reason  => 'test reason'
    };
    my $handler = BOM::Event::Process::get_action_mappings()->{account_reactivated};

    mailbox_clear();
    ok $handler->($call_args), 'Event processed successfully';
    my $msg = mailbox_search(subject => qr/Welcome back! Your account is ready./);
    ok $msg, 'Email to client is found';
    like $msg->{body},    qr/Check your personal details/, 'Email contains link to profile page';
    unlike $msg->{body},  qr/Upload your documents/,       'No link to POI page';
    is_deeply $msg->{to}, [$test_client->email], 'Client email address is correct';

    $needs_verification = 1;
    mailbox_clear();
    ok $handler->($call_args), 'Event processed successfully';
    $msg = mailbox_search(subject => qr/Welcome back! Your account is ready./);
    ok $msg, 'Email to client is found';
    unlike $msg->{body},  qr/Check your personal details/, 'Email contains link to profile page';
    like $msg->{body},    qr/Upload your documents/,       'No link to POI page';
    is_deeply $msg->{to}, [$test_client->email], 'Client email address is correct';

    ok $handler->($call_args), 'Event processed successfully';
    $msg = mailbox_search(subject => qr/has been reactivated/);
    ok !$msg, 'No SR email is sent';

    $social_responsibility = 1;
    mailbox_clear();
    ok $handler->($call_args), 'Event processed successfully';
    $msg = mailbox_search(subject => qr/has been reactivated/);
    ok $msg, 'Email to SR team is found';
    is_deeply $msg->{to}, [request->brand->emails('social_responsibility')], 'SR email address is correct';
};

subtest 'withdrawal_limit_reached' => sub {
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $is_poa_pending;
    my $fully_authenticated;

    $client_mock->mock(
        'documents_uploaded',
        sub {
            return {proof_of_address => {is_pending => $is_poa_pending}};
        });

    $client_mock->mock(
        'fully_authenticated',
        sub {
            return $fully_authenticated;
        });

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $handler   = BOM::Event::Process::get_action_mappings()->{withdrawal_limit_reached};
    my $call_args = {
        loginid => $test_client->loginid,
    };

    throws_ok(
        sub {
            $handler->();
        },
        qr/\bClient login ID was not given\b/,
        'Expected exception thrown, clientid was not given'
    );

    throws_ok(
        sub {
            $handler->({loginid => 'CR0'});
        },
        qr/\bCould not instantiate client for login ID CR0\b/,
        'Expected exception thrown, clientid was not found'
    );

    $fully_authenticated = 1;
    $is_poa_pending      = 1;
    $handler->($call_args);
    $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
    ok !$test_client->status->allow_document_upload, 'Allow document upload not set';

    $fully_authenticated = 1;
    $is_poa_pending      = 0;
    $handler->($call_args);
    $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
    ok !$test_client->status->allow_document_upload, 'Allow document upload not set';

    $fully_authenticated = 0;
    $is_poa_pending      = 1;
    $handler->($call_args);
    $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
    ok !$test_client->status->allow_document_upload, 'Allow document upload not set';

    $fully_authenticated = 0;
    $is_poa_pending      = 0;
    $handler->($call_args);
    $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
    is $test_client->status->reason('allow_document_upload'), 'WITHDRAWAL_LIMIT_REACHED', 'Allow Document upload with custom reason set';

    $client_mock->unmock_all;
};

subtest 'POA email notification' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $test_client->status->setnx('age_verification', 'test', 'test');

    mailbox_clear();
    BOM::Event::Actions::Client::_send_CS_email_POA_uploaded($test_client)->get;

    my $msg = mailbox_search(subject => qr/New uploaded POA document for/);
    ok $msg, 'First email sent';

    mailbox_clear();
    BOM::Event::Actions::Client::_send_CS_email_POA_uploaded($test_client)->get;

    $msg = mailbox_search(subject => qr/New uploaded POA document for/);
    ok $msg, 'Second email sent';
};

subtest 'verify address' => sub {
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $residence;

    $client_mock->mock(
        'residence',
        sub {
            return $residence;
        });

    my $licenses = {
        au   => 'international-global-plus-cloud',
        jp   => 'international-global-plus-cloud',
        de   => 'international-global-plus-cloud',
        in   => 'international-global-plus-cloud',
        gb   => 'international-global-plus-cloud',
        ''   => 'international-select-basic-cloud',
        'py' => 'international-select-basic-cloud',
        'us' => 'international-select-basic-cloud',
        'tz' => 'international-select-basic-cloud',
        'zw' => 'international-select-basic-cloud',
        'za' => 'international-select-basic-cloud',
    };

    subtest 'licenses' => sub {
        for my $country_code (keys $licenses->%*) {
            $residence = $country_code;

            is BOM::Event::Actions::Client::_smarty_license($test_client), $licenses->{$residence}, "Expected license for '$country_code'";
        }

        # undef should yield the cheaper license
        $residence = undef;
        is BOM::Event::Actions::Client::_smarty_license($test_client), $licenses->{''}, "Expected license for 'undef'";
    };

    $residence = 'br';
    my $events_mock  = Test::MockModule->new('BOM::Event::Actions::Client');
    my $dd_mock      = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my $redis_mock   = Test::MockModule->new('Net::Async::Redis');
    my $smarty_mock  = Test::MockModule->new('WebService::Async::SmartyStreets');
    my $address_mock = Test::MockModule->new('WebService::Async::SmartyStreets::Address');

    my $address_verification_future;
    my $fully_authenticated;
    my $has_deposits;
    my $dd_bag;
    my $check_already_performed;
    my $verify_details;
    my $verify_future;
    my $address_status;
    my $address_accuracy_at_least;
    my $redis_hset_data;

    $address_mock->mock(
        'address_precision',
        sub {
            return 'awful';
        });

    $address_mock->mock(
        'accuracy_at_least',
        sub {
            return $address_accuracy_at_least;
        });

    $address_mock->mock(
        'status',
        sub {
            return $address_status;
        });

    $smarty_mock->mock(
        'verify',
        sub {
            my (undef, %args) = @_;
            $verify_details = {%args};
            return $verify_future;
        });

    $redis_mock->mock(
        'hget',
        sub {
            return Future->done($check_already_performed);
        });

    $redis_mock->mock(
        'hset',
        sub {
            my (undef, $hash, $key, $val) = @_;
            $redis_hset_data->{$hash}->{$key} = $val;
            return Future->done();
        });

    $dd_mock->mock(
        'stats_inc',
        sub {
            my ($event, $args) = @_;
            $dd_bag->{$event} = $args;
            return;
        });

    $client_mock->mock(
        'has_deposits',
        sub {
            return $has_deposits;
        });

    $client_mock->mock(
        'fully_authenticated',
        sub {
            return $fully_authenticated;
        });

    $events_mock->mock(
        '_address_verification',
        sub {
            return $address_verification_future // $events_mock->original('_address_verification')->(@_);
        });

    my $handler   = BOM::Event::Process::get_action_mappings()->{verify_address};
    my $call_args = {};

    like exception { $handler->($call_args)->get }, qr/No client login ID supplied\?/, 'Expected exception for empty args';

    $call_args->{loginid} = 'CR0';
    like exception { $handler->($call_args)->get }, qr/Could not instantiate client for login ID CR0/,
        'Expected exception when bogus loginid is given';

    $call_args->{loginid} = $test_client->loginid;
    $has_deposits         = 0;
    $fully_authenticated  = 0;
    $dd_bag               = {};

    is exception { $handler->($call_args)->get }, undef, 'The event made it alive';
    cmp_deeply $dd_bag,
        {
        'event.address_verification.request' => undef,
        },
        'Expected data for the data pooch';

    $address_verification_future = Future->done;
    $has_deposits                = 1;
    $fully_authenticated         = 0;
    $dd_bag                      = {};

    is exception { $handler->($call_args)->get }, undef, 'The event made it alive';
    cmp_deeply $dd_bag,
        {
        'event.address_verification.request'   => undef,
        'event.address_verification.triggered' => {tags => ['verify_address:deposits']},
        },
        'Expected data for the data pooch';

    $address_verification_future = Future->fail('testing it');
    $has_deposits                = 1;
    $fully_authenticated         = 0;
    $dd_bag                      = {};

    is exception { $handler->($call_args)->get }, undef, 'The event made it alive';
    cmp_deeply $dd_bag,
        {
        'event.address_verification.request'   => undef,
        'event.address_verification.triggered' => {tags => ['verify_address:deposits']},
        'event.address_verification.exception' => {tags => ['verify_address:deposits']}
        },
        'Expected data for the data pooch';

    $address_verification_future = Future->done;
    $has_deposits                = 0;
    $fully_authenticated         = 1;
    $dd_bag                      = {};

    is exception { $handler->($call_args)->get }, undef, 'The event made it alive';
    cmp_deeply $dd_bag,
        {
        'event.address_verification.request'   => undef,
        'event.address_verification.triggered' => {tags => ['verify_address:authenticated']}
        },
        'Expected data for the data pooch';

    $address_verification_future = Future->fail('testing it');
    $has_deposits                = 0;
    $fully_authenticated         = 1;
    $dd_bag                      = {};

    is exception { $handler->($call_args)->get }, undef, 'The event made it alive';
    cmp_deeply $dd_bag,
        {
        'event.address_verification.request'   => undef,
        'event.address_verification.triggered' => {tags => ['verify_address:authenticated']},
        'event.address_verification.exception' => {tags => ['verify_address:authenticated']}
        },
        'Expected data for the data pooch';

    # From this point, the test coverage reaches to _address_verification
    # so $address_verification_future = undef

    $has_deposits                = 0;
    $fully_authenticated         = 1;
    $dd_bag                      = {};
    $check_already_performed     = 1;
    $address_verification_future = undef;

    is exception { $handler->($call_args)->get }, undef, 'The event made it alive';
    cmp_deeply $dd_bag,
        {
        'event.address_verification.request'        => undef,
        'event.address_verification.triggered'      => {tags => ['verify_address:authenticated']},
        'event.address_verification.already_exists' => undef,
        },
        'Expected data for the data pooch';

    # We're about to hit smarty streets wrapper (mocked)

    $has_deposits                = 0;
    $fully_authenticated         = 1;
    $dd_bag                      = {};
    $check_already_performed     = 0;
    $address_verification_future = undef;
    $verify_future               = Future->fail('failure');

    is exception { $handler->($call_args)->get }, undef, 'The event made it alive';
    cmp_deeply $dd_bag,
        {
        'event.address_verification.request'   => undef,
        'event.address_verification.triggered' => {tags => ['verify_address:authenticated']},
        'smartystreet.verification.trigger'    => undef,
        'smartystreet.lookup.failure'          => undef,
        'event.address_verification.exception' => {tags => ['verify_address:authenticated']},
        },
        'Expected data for the data pooch';

    # verify done but $address_accuracy_at_least = 0
    # country = au, so we'd expect an expensive license

    $residence                   = 'au';
    $has_deposits                = 0;
    $fully_authenticated         = 1;
    $dd_bag                      = {};
    $check_already_performed     = 0;
    $address_verification_future = undef;
    $verify_future               = Future->done(WebService::Async::SmartyStreets::Address->new);
    $address_status              = 'test';
    $address_accuracy_at_least   = 0;
    $redis_hset_data             = {};
    $verify_details              = {};

    is exception { $handler->($call_args)->get }, undef, 'The event made it alive';
    cmp_deeply $dd_bag,
        {
        'event.address_verification.request'        => undef,
        'event.address_verification.triggered'      => {tags => ['verify_address:authenticated']},
        'smartystreet.verification.trigger'         => undef,
        'smartystreet.verification.failure'         => {tags => ['verify_address:test']},
        'smartystreet.lookup.success'               => undef,
        'event.address_verification.recorded.redis' => undef,
        },
        'Expected data for the data pooch';

    my $freeform = join(' ',
        grep { length } $test_client->address_line_1,
        $test_client->address_line_2,
        $test_client->address_city,
        $test_client->address_state,
        $test_client->address_postcode);

    cmp_deeply $verify_details,
        {
        freeform => $freeform,
        country  => uc(country_code2code($test_client->residence, 'alpha-2', 'alpha-3')),
        license  => 'international-global-plus-cloud',
        },
        'Expected verify arguments';

    cmp_deeply $redis_hset_data,
        {'ADDRESS_VERIFICATION_RESULT'
            . $test_client->binary_user_id => {encode_utf8(join(' ', ($freeform, ($test_client->residence // '')))) => 'test'}},
        'Expected data recorded to Redis';

    # verify done and $address_accuracy_at_least = 1
    # country = br, so we'd expect a cheap license

    $residence                   = 'br';
    $has_deposits                = 0;
    $fully_authenticated         = 1;
    $dd_bag                      = {};
    $check_already_performed     = 0;
    $address_verification_future = undef;
    $verify_future               = Future->done(WebService::Async::SmartyStreets::Address->new);
    $address_status              = 'awesome';
    $address_accuracy_at_least   = 1;
    $redis_hset_data             = {};
    $verify_details              = {};

    is exception { $handler->($call_args)->get }, undef, 'The event made it alive';
    cmp_deeply $dd_bag,
        {
        'event.address_verification.request'        => undef,
        'event.address_verification.triggered'      => {tags => ['verify_address:authenticated']},
        'smartystreet.verification.trigger'         => undef,
        'smartystreet.verification.success'         => {tags => ['verify_address:awesome']},
        'smartystreet.lookup.success'               => undef,
        'event.address_verification.recorded.redis' => undef,
        },
        'Expected data for the data pooch';

    cmp_deeply $verify_details,
        {
        freeform => $freeform,
        country  => uc(country_code2code($test_client->residence, 'alpha-2', 'alpha-3')),
        license  => 'international-select-basic-cloud',
        },
        'Expected verify arguments';

    cmp_deeply $redis_hset_data,
        {'ADDRESS_VERIFICATION_RESULT'
            . $test_client->binary_user_id => {encode_utf8(join(' ', ($freeform, ($test_client->residence // '')))) => 'awesome'}},
        'Expected data recorded to Redis';

    $dd_mock->unmock_all;
    $client_mock->unmock_all;
    $events_mock->unmock_all;
    $redis_mock->unmock_all;
    $smarty_mock->unmock_all;
    $address_mock->unmock_all;
};

subtest 'Deriv X events' => sub {

    my @events = qw(trading_platform_account_created trading_platform_password_reset_request trading_platform_password_changed
        trading_platform_password_change_failed trading_platform_investor_password_reset_request trading_platform_investor_password_changed
        trading_platform_investor_password_change_failed);

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    for my $event (@events) {
        my $payload = {
            loginid    => $client->loginid,
            properties => {
                first_name => rand(1000),
            }};

        undef @track_args;
        no strict 'refs';
        &{"BOM::Event::Actions::Client::$event"}($payload)->get;

        my ($customer, %args) = @track_args;
        is $args{event}, $event, "$event event name";
        is $args{properties}{first_name}, $payload->{properties}{first_name}, "$event properties";
        is $customer->traits->{email}, $client->email, "$event customer email";
    }

};

done_testing();
