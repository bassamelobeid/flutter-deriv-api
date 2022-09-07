use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Test::Fatal;
use Test::Deep;
use Guard;
use Log::Any::Test;
use Log::Any                                   qw($log);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);

use BOM::Test::Email;
use BOM::Database::UserDB;
use BOM::Database::ClientDB;
use BOM::User;
use BOM::Test::Script::OnfidoMock;
use BOM::Platform::Context           qw(request);
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);

use WebService::Async::Onfido;
use BOM::Event::Actions::Client;
use BOM::Event::Process;
use BOM::User::Onfido;
use BOM::Config::Redis;
use BOM::Config::Runtime;

use WebService::Async::SmartyStreets::Address;
use Encode                 qw(encode_utf8);
use Locale::Codes::Country qw(country_code2code);
use JSON::MaybeUTF8        qw(decode_json_utf8 encode_json_utf8);

my $vrtc_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => 'vrtc+test1@bin.com',
});

my $brand = Brands->new(name => 'deriv');
my ($app_id) = $brand->whitelist_apps->%*;

my (@identify_args, @track_args);
my $mock_segment = Test::MockModule->new('WebService::Async::Segment::Customer');

$mock_segment->redefine(
    'identify' => sub {
        @identify_args = @_;
        return Future->done(1);
    },
    'track' => sub {
        @track_args = @_;
        return Future->done(1);
    });

my @emit_args;
my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_emitter->mock('emit', sub { push @emit_args, @_ });

my @enabled_brands = ('deriv', 'binary');
my $mock_brands    = Test::MockModule->new('Brands');

my $mock_service_config = Test::MockModule->new('BOM::Config::Services');
$mock_service_config->mock(is_enabled => 0);

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
$test_client->place_of_birth('co');
$test_client->binary_user_id($test_user->id);
$test_client->save;
$test_sibling->binary_user_id($test_user->id);
$test_sibling->save;

mailbox_clear();

BOM::Event::Actions::Common::_email_client_age_verified($test_client);

is_deeply \@emit_args,
    [
    'age_verified',
    {
        loginid    => $test_client->loginid,
        properties => {
            contact_url   => 'https://deriv.com/en/contact-us',
            poi_url       => 'https://app.deriv.com/account/proof-of-identity?lang=en',
            live_chat_url => 'https://deriv.com/en/?is_livechat_open=true',
            email         => $test_client->email,
            name          => $test_client->first_name,
            website_name  => 'Deriv.com'
        }}
    ],
    'Age verified client';

undef @emit_args;

$test_client->status->set('age_verification');

BOM::Event::Actions::Common::_email_client_age_verified($test_client);

is scalar @emit_args, 0, "Didn't send email when already age verified";
undef @emit_args;

my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
});

BOM::Event::Actions::Common::_email_client_age_verified($test_client_mx);

is scalar @emit_args, 0, "No email for non CR account";
undef @emit_args;

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
BOM::Event::Actions::Client::authenticated_with_scans({loginid => $test_client_cr->loginid})->get;

my $msg = mailbox_search(subject => qr/Your address and identity have been verified successfully/);

my $args = {
    document_type     => 'proofaddress',
    document_format   => 'PNG',
    document_id       => undef,
    expiration_date   => undef,
    expected_checksum => '12345',
    page_type         => undef,

};

sub start_document_upload {
    my ($document_args, $client) = @_;

    return $client->db->dbic->run(
        ping => sub {
            $_->selectrow_hashref(
                'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?)', undef,
                $client->loginid,                                                           $document_args->{document_type},
                $document_args->{document_format}, $document_args->{expiration_date} || undef,
                $document_args->{document_id} || '', $document_args->{expected_checksum},
                '', $document_args->{page_type} || '',
            );
        });
}

my ($applicant, $applicant_id, $loop, $onfido);
subtest 'upload document' => sub {
    $loop = IO::Async::Loop->new;

    subtest 'upload POA documents' => sub {
        my $upload_info = start_document_upload($args, $test_client);

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

        mailbox_clear();

        BOM::Event::Actions::Client::document_upload({
                loginid => $test_client->loginid,
                file_id => $upload_info->{file_id}})->get;

        my $applicant = BOM::Database::UserDB::rose_db()->dbic->run(
            fixup => sub {
                my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $test_client->user_id);
            });

        my $email = mailbox_search(subject => qr/Manual age verification needed for/);
        ok !$email, 'Not a POI, no email sent to CS';

        is $applicant, undef, 'POA does not populate to onfido';

        my $resubmission_flag_after = $test_client->status->_get('allow_poa_resubmission');
        ok !$resubmission_flag_after, 'poa resubmission status is removed after document uploading';

        my $sibling_resubmission_flag_after = $test_sibling->status->_get('allow_poa_resubmission');
        ok !$sibling_resubmission_flag_after, 'poa resubmission status is removed from the sibling after document uploading';
    };

    my $args = {
        document_type     => 'passport',
        document_format   => 'PDF',
        document_id       => undef,
        expiration_date   => undef,
        expected_checksum => '12345',
        page_type         => undef,
    };

    subtest 'upload POI documents' => sub {
        my $upload_info = start_document_upload($args, $test_client);

        subtest 'document type is not supported' => sub {
            my $tests = [{
                    document_type => 'tax_photo_id',
                    by_staff      => 1,
                    email_sent    => 0,
                    checksum      => 'tax_photo_id_1',
                },
                {
                    document_type => 'nimc_slip',
                    by_staff      => 0,
                    email_sent    => 1,
                    checksum      => 'nimc_slip_1',
                },
                {
                    document_type => 'tax_photo_id',
                    by_staff      => 0,
                    email_sent    => 1,
                    checksum      => 'tax_photo_id_2',
                },
                {
                    document_type => 'nimc_slip',
                    by_staff      => 1,
                    email_sent    => 0,
                    checksum      => 'nimc_slip_2',
                }];

            for my $test_case ($tests->@*) {
                my ($document_type, $by_staff, $email_sent, $checksum) = @{$test_case}{qw/document_type by_staff email_sent checksum/};

                subtest $document_type => sub {
                    my $old_pob  = $upload_info;
                    my $old_args = $args;

                    scope_guard {
                        $upload_info = $old_pob;
                        $test_client->db->dbic->run(
                            ping => sub {
                                $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
                            });

                        $args = $old_args;
                    };

                    # Redis key for resubmission flag
                    $test_client->status->set('allow_poi_resubmission', 'test', 'test');
                    $test_client->copy_status_to_siblings('allow_poi_resubmission', 'test');
                    ok $test_sibling->status->_get('allow_poi_resubmission'), 'POI flag propagated to siblings';

                    $args = {
                        document_type     => $document_type,
                        document_format   => 'PDF',
                        document_id       => undef,
                        expiration_date   => undef,
                        expected_checksum => $checksum,
                        page_type         => undef,
                    };

                    $upload_info = start_document_upload($args, $test_client);

                    $test_client->db->dbic->run(
                        ping => sub {
                            $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
                        });

                    mailbox_clear();

                    BOM::Event::Actions::Client::document_upload({
                            uploaded_manually_by_staff => $by_staff,
                            loginid                    => $test_client->loginid,
                            file_id                    => $upload_info->{file_id}})->get;

                    my $loginid = $test_client->loginid;
                    $log->contains_ok(qr/Unsupported document by onfido $args->{document_type}*/,
                        'error log: POI document type is not supported by onfido');

                    my $email = mailbox_search(subject => qr/Manual age verification needed for/);

                    if ($email_sent) {
                        ok $email, 'POI not supported by Onfido sends an email';
                    } else {
                        ok !$email, 'Email not send when uploaded by staff';
                    }

                    my $applicant = BOM::Database::UserDB::rose_db()->dbic->run(
                        fixup => sub {
                            my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $test_client->user_id);
                        });

                    ok !$applicant, 'Unsupported POI document does not upload to onfido';

                    my $resubmission_flag_after = $test_client->status->_get('allow_poi_resubmission');
                    ok !$resubmission_flag_after, 'poi resubmission status is removed after document uploading';

                    my $sibling_resubmission_flag_after = $test_sibling->status->_get('allow_poi_resubmission');
                    ok !$sibling_resubmission_flag_after, 'poi resubmission status is removed from the sibling after document uploading';
                }
            }
        };

        subtest 'Forged document email trigger' => sub {
            my $tests = [{
                    title         => 'Not a POI document',
                    document_type => 'utility_bill',
                    by_staff      => 0,
                    email         => 0,
                    checksum      => 'utility_bill_forged' . time,
                    reason        => undef,
                },
                {
                    title         => 'POI but uploaded by stafff',
                    document_type => 'passport',
                    by_staff      => 1,
                    email         => 0,
                    checksum      => 'passport_forged_1' . time,
                    reason        => undef,
                },
                {
                    title         => 'Forged reason is not set',
                    document_type => 'passport',
                    by_staff      => 0,
                    email         => 0,
                    checksum      => 'passport_forged_2' . time,
                    reason        => 'all good'
                },
                {
                    title         => 'Triggers the email',
                    document_type => 'passport',
                    by_staff      => 0,
                    email         => 1,
                    checksum      => 'passport_forged_3' . time,
                    reason        => 'Forged document'
                },
            ];

            for my $test ($tests->@*) {
                my ($title, $document_type, $by_staff, $email_sent, $checksum, $reason) =
                    @{$test}{qw/title document_type by_staff email checksum reason/};

                subtest $title => sub {
                    my $args = {
                        document_type     => $document_type,
                        document_format   => 'PNG',
                        document_id       => undef,
                        expiration_date   => undef,
                        expected_checksum => $checksum,
                        page_type         => undef,
                    };

                    my $upload_info = start_document_upload($args, $test_client);

                    $test_client->db->dbic->run(
                        ping => sub {
                            $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
                        });

                    mailbox_clear();
                    $test_client->status->clear_cashier_locked;
                    $test_client->status->set('cashier_locked', 'test', $reason);

                    BOM::Event::Actions::Client::document_upload({
                            uploaded_manually_by_staff => $by_staff,
                            loginid                    => $test_client->loginid,
                            file_id                    => $upload_info->{file_id}})->get;

                    my $email = mailbox_search(subject => qr/New POI uploaded for acc with forged lock/);
                    if ($email_sent) {
                        ok $email, 'Onfido uploaded document when client has forged documents sends an email';
                    } else {
                        ok !$email, 'Email not send';
                    }
                };
            }
        };

        subtest 'password reset' => sub {
            my $req = BOM::Platform::Context::Request->new(
                brand_name => 'deriv',
                language   => 'ID',
                app_id     => $app_id,
            );
            request($req);
            undef @identify_args;
            undef @track_args;

            my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $args = {
                loginid    => $test_client->loginid,
                properties => {
                    first_name       => 'Potato',
                    verification_url => 'https://ver.url',
                    social_login     => 1,
                    email            => 'potato@binary.com',
                    lost_password    => 1,
                    code             => 'CODEE',
                    language         => 'en',
                }};

            my $handler = BOM::Event::Process->new(category => 'track')->actions->{reset_password_request};
            my $result  = $handler->($args)->get;
            ok $result, 'Success result';
            is scalar @track_args, 7, 'Track event is triggered';
        };

        subtest 'reset_password_confirmation' => sub {
            my $req = BOM::Platform::Context::Request->new(
                brand_name => 'deriv',
                language   => 'ID',
                app_id     => $app_id,
            );
            request($req);
            undef @identify_args;
            undef @track_args;

            my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            my $args = {
                loginid    => $test_client->loginid,
                properties => {
                    first_name => 'Potato',
                    type       => 'reset_password',
                }};

            my $handler = BOM::Event::Process->new(category => 'track')->actions->{reset_password_confirmation};
            my $result  = $handler->($args)->get;

            ok $result, 'Success result';
            is scalar @track_args, 7, 'Track event is triggered';
        };

        # Redis key for resubmission flag
        $test_client->status->set('allow_poi_resubmission', 'test', 'test');
        $test_client->copy_status_to_siblings('allow_poi_resubmission', 'test');
        ok $test_sibling->status->_get('allow_poi_resubmission'), 'POI flag propagated to siblings';

        my $mocked_action    = Test::MockModule->new('BOM::Event::Actions::Client');
        my $document_content = 'it is a passport document';
        $mocked_action->mock('_get_document_s3', sub { return Future->done($document_content) });

        mailbox_clear();

        BOM::Event::Actions::Client::document_upload({
                loginid => $test_client->loginid,
                file_id => $upload_info->{file_id}})->get;

        my $email = mailbox_search(subject => qr/Manual age verification needed for/);
        ok !$email, 'Since is an Onfido document, no email is sent to CS';

        my $applicant = BOM::Database::UserDB::rose_db()->dbic->run(
            fixup => sub {
                my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $test_client->user_id);
            });

        ok $applicant, 'There is an applicant data in db';
        $applicant_id = $applicant->{id};
        ok $applicant_id, 'applicant id ok';

        my $resubmission_flag_after = $test_client->status->_get('allow_poi_resubmission');
        ok !$resubmission_flag_after, 'poi resubmission status is removed after document uploading';

        my $sibling_resubmission_flag_after = $test_sibling->status->_get('allow_poi_resubmission');
        ok !$sibling_resubmission_flag_after, 'poi resubmission status is removed from the sibling after document uploading';

        $loop->add(
            $onfido = WebService::Async::Onfido->new(
                token    => 'test',
                base_uri => $ENV{ONFIDO_URL}));

        my $doc = $onfido->document_list(applicant_id => $applicant_id)->as_arrayref->get->[0];
        ok($doc, "there is a document");

        # Redis key for resubmission flag
        $test_client->status->set('allow_poi_resubmission', 'test', 'test');
        $test_client->copy_status_to_siblings('allow_poi_resubmission', 'test');
        ok $test_sibling->status->_get('allow_poi_resubmission'), 'POI flag propagated to siblings';

        BOM::Event::Actions::Client::document_upload({
                loginid => $test_client->loginid,
                file_id => $upload_info->{file_id}})->get;

        $applicant = BOM::Database::UserDB::rose_db()->dbic->run(
            fixup => sub {
                my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $test_client->user_id);
            });

        ok $applicant, 'There is an applicant data in db';
        $applicant_id = $applicant->{id};
        ok $applicant_id, 'applicant id ok';

        $resubmission_flag_after = $test_client->status->_get('allow_poi_resubmission');
        ok !$resubmission_flag_after, 'poi resubmission status is removed after document uploading';

        $sibling_resubmission_flag_after = $test_sibling->status->_get('allow_poi_resubmission');
        ok !$sibling_resubmission_flag_after, 'poi resubmission status is removed from the sibling after document uploading';

        $loop->add(
            $onfido = WebService::Async::Onfido->new(
                token    => 'test',
                base_uri => $ENV{ONFIDO_URL}));

        $doc = $onfido->document_list(applicant_id => $applicant_id)->as_arrayref->get->[0];
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
};

my $check;
subtest "ready for run authentication" => sub {
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @metrics;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @metrics, @_;
            return 1;
        });

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
        @metrics = ();
        BOM::Event::Actions::Client::ready_for_authentication({
                loginid      => $test_client->loginid,
                applicant_id => $applicant_id,
            })->get;

        cmp_deeply + {@metrics},
            +{
            'event.onfido.ready_for_authentication.dispatch' => {tags => ['country:COL']},
            'event.onfido.check_applicant.dispatch'          => {tags => ['country:COL']},
            'event.onfido.check_applicant.success'           => {tags => ['country:COL']},
            'event.onfido.ready_for_authentication.success'  => {tags => ['country:COL']},
            },
            'Expected dd metrics';
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

    subtest 'consecutive calls to ready_for_authentication' => sub {
        my $lock_mock = Test::MockModule->new('BOM::Platform::Redis');
        my $lock;
        $lock_mock->mock(
            'acquire_lock',
            sub {
                $lock = $lock_mock->original('acquire_lock')->(@_);
                return $lock;
            });
        $lock_mock->mock(
            'release_lock',
            sub {
                $lock = 0;
                return $lock_mock->original('release_lock')->(@_);
            });
        my $consecutive_cli = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        my $user = BOM::User->create(
            email          => 'consec@test.com',
            password       => "hello",
            email_verified => 1,
            email_consent  => 1,
        );

        $user->add_client($consecutive_cli);
        $consecutive_cli->binary_user_id($user->id);
        $consecutive_cli->save;

        my $consecutive_applicant = $onfido->applicant_create(
            first_name => 'Mary',
            last_name  => 'Jane',
            dob        => '1999-02-02',
        )->get;
        BOM::User::Onfido::store_onfido_applicant($consecutive_applicant, $consecutive_cli->binary_user_id);

        my $checks_counter = 0;

        $onfido_mocker->mock(
            'applicant_check',
            sub {
                $checks_counter++;
                ok $lock, 'lock acquired';

                return $onfido_mocker->original('applicant_check')->(@_);
            });

        my $generator = sub {
            $redis->del(BOM::Event::Actions::Client::ONFIDO_REQUEST_PER_USER_PREFIX . $consecutive_cli->binary_user_id)->get;
            my $f = BOM::Event::Actions::Client::ready_for_authentication({
                loginid      => $consecutive_cli->loginid,
                applicant_id => $consecutive_applicant->id,
            });
            return $f;
        };

        @metrics = ();
        my $f = Future->wait_all(map { $generator->() } (1 .. 20));
        $f->on_ready(
            sub {
                my $checks = $onfido->check_list(applicant_id => $consecutive_applicant->id)->as_arrayref->get;
                is scalar @$checks, $checks_counter, 'Expected checks counter';
                is $checks_counter, 1,               'One check done';

                cmp_deeply + {@metrics},
                    +{
                    'event.onfido.ready_for_authentication.dispatch' => {tags => ['country:IDN']},
                    'event.onfido.check_applicant.dispatch'          => {tags => ['country:IDN']},
                    'event.onfido.check_applicant.success'           => {tags => ['country:IDN']},
                    'event.onfido.ready_for_authentication.success'  => {tags => ['country:IDN']},
                    'event.onfido.ready_for_authentication.failure'  => {tags => ['country:IDN']},
                    },
                    'Expected dd metrics';
            });
        $f->get;
        $lock_mock->unmock_all;
    };

    $onfido_mocker->unmock_all;
    $ryu_mock->unmock_all;
    $dog_mock->unmock_all;
};

my $services;
subtest "client_verification" => sub {
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @metrics;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @metrics, @_ if scalar @_ == 2;
            push @metrics, @_, undef if scalar @_ == 1;

            return 1;
        });

    $loop->add($services = BOM::Event::Services->new);
    my $redis_write = $services->redis_events_write();
    $redis_write->connect->get;
    mailbox_clear();

    my $redis_r_write = $services->redis_replicated_write();
    my $keys          = $redis_r_write->keys('*APPLICANT_CHECK_LOCK*')->get;

    my $redis_mock = Test::MockModule->new(ref($redis_r_write));
    my $db_doc_id;
    my $doc_key;
    $redis_mock->mock(
        'del',
        sub {
            my ($self, $key) = @_;
            $doc_key   = $key;
            $db_doc_id = $self->get($key)->get if $key =~ qr/^ONFIDO::DOCUMENT::ID::/;

            return $redis_mock->original('del')->(@_);
        });

    for my $key (@$keys) {
        $redis_r_write->del($key)->get;
    }

    my $lock_key = 'BOM::Event::Actions::Client_LOCK_ONFIDO::APPLICANT_CHECK_LOCK::' . $test_client->binary_user_id;
    $redis_r_write->set($lock_key, 1, 'NX', 'EX', 30);
    $keys = $redis_r_write->keys('*APPLICANT_CHECK_LOCK*')->get;
    is scalar @$keys, 1, 'Lock acquired';

    lives_ok {
        @metrics = ();
        BOM::Event::Actions::Client::client_verification({
                check_url => $check->{href},
            })->get;

        cmp_deeply + {@metrics},
            +{
            'event.onfido.client_verification.dispatch'         => undef,
            'event.onfido.client_verification.not_verified'     => {tags => ['check:clear', 'country:COL', 'report:clear']},
            'event.onfido.client_verification.dob_not_reported' => {tags => ['check:clear', 'country:COL', 'report:clear']},
            'event.onfido.client_verification.success'          => undef,
            },
            'Expected dd metrics';

        my $keys = $redis_r_write->keys('*APPLICANT_CHECK_LOCK*')->get;
        is scalar @$keys, 0, 'Lock released';

        $keys = $redis_r_write->keys('ONFIDO::REQUEST::PENDING::PER::USER::*')->get;
        is scalar @$keys, 0, 'Pending lock released';

        my ($db_doc) = $test_client->find_client_authentication_document(query => [id => $db_doc_id]);
        is $db_doc->status, 'verified', 'upload doc status is verified';
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

    lives_ok {
        $redis_write->set($doc_key, $db_doc_id)->get;
        $db_doc_id = undef;

        my $mocked_report = Test::MockModule->new('WebService::Async::Onfido::Report');

        $mocked_report->mock(
            'result',
            sub {
                return 'consider';
            });

        @metrics = ();
        BOM::Event::Actions::Client::client_verification({
                check_url => $check->{href},
            })->get;
        cmp_deeply + {@metrics},
            +{
            'event.onfido.client_verification.dispatch'         => undef,
            'event.onfido.client_verification.not_verified'     => {tags => ['check:clear', 'country:COL', 'report:consider']},
            'event.onfido.client_verification.dob_not_reported' => {tags => ['check:clear', 'country:COL', 'report:consider']},
            'event.onfido.client_verification.success'          => undef,
            },
            'Expected dd metrics';

        my $keys = $redis_r_write->keys('*APPLICANT_CHECK_LOCK*')->get;
        is scalar @$keys, 0, 'Lock released';

        $keys = $redis_r_write->keys('ONFIDO::REQUEST::PENDING::PER::USER::*')->get;
        is scalar @$keys, 0, 'Pending lock released';

        my ($db_doc) = $test_client->find_client_authentication_document(query => [id => $db_doc_id]);
        is $db_doc->status, 'rejected', 'upload doc status is rejected';

        $mocked_report->unmock_all;
    }
    "client verification no exception, rejected result";

    $redis_mock->unmock_all;

    subtest 'forged email' => sub {
        my $redis_write = $services->redis_events_write();
        $redis_write->del('FORGED::EMAIL::LOCK::' . $test_client->loginid)->get;

        mailbox_clear();
        $test_client->status->clear_cashier_locked;
        $test_client->status->set('cashier_locked', 'test', 'Forged documents');

        lives_ok {
            @metrics = ();
            BOM::Event::Actions::Client::client_verification({
                    check_url => $check->{href},
                })->get;
            cmp_deeply + {@metrics},
                +{
                'event.onfido.client_verification.dispatch'         => undef,
                'event.onfido.client_verification.not_verified'     => {tags => ['check:clear', 'country:COL', 'report:clear']},
                'event.onfido.client_verification.dob_not_reported' => {tags => ['check:clear', 'country:COL', 'report:clear']},
                'event.onfido.client_verification.success'          => undef,
                },
                'Expected dd metrics';
        }
        "client verification no exception";

        my $msg = mailbox_search(subject => qr/New POI uploaded for acc with forged lock/);
        ok $msg,                                                                    'Email sent';
        ok $redis_write->ttl('FORGED::EMAIL::LOCK::' . $test_client->loginid)->get, 'Cooldown has been set';

        mailbox_clear();

        lives_ok {
            @metrics = ();
            BOM::Event::Actions::Client::client_verification({
                    check_url => $check->{href},
                })->get;
            cmp_deeply + {@metrics},
                +{
                'event.onfido.client_verification.dispatch'         => undef,
                'event.onfido.client_verification.not_verified'     => {tags => ['check:clear', 'country:COL', 'report:clear']},
                'event.onfido.client_verification.dob_not_reported' => {tags => ['check:clear', 'country:COL', 'report:clear']},
                'event.onfido.client_verification.success'          => undef,
                },
                'Expected dd metrics';
        }
        "client verification no exception";

        $msg = mailbox_search(subject => qr/New POI uploaded for acc with forged lock/);
        ok !$msg, 'Email not sent (on cooldown)';
    };
};

subtest "Uninitialized date of birth" => sub {
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @metrics;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @metrics, @_ if scalar @_ == 2;
            push @metrics, @_, undef if scalar @_ == 1;

            return 1;
        });

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
        @metrics = ();
        BOM::Event::Actions::Client::client_verification({
                check_url => $check->{href},
            })->get;

        cmp_deeply + {@metrics},
            +{
            'event.onfido.client_verification.dispatch'      => undef,
            'event.onfido.client_verification.not_verified'  => {tags => ['check:clear', 'country:COL', 'report:clear']},
            'event.onfido.client_verification.name_mismatch' => {tags => ['check:clear', 'country:COL', 'report:clear']},
            'event.onfido.client_verification.success'       => undef,
            },
            'Expected dd metrics';
    }
    "client verification should pass with undef dob";

    $mocked_client->unmock_all();
    $mocked_report->unmock_all();
    $dog_mock->unmock_all;
};

subtest "document upload request context" => sub {
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @metrics;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @metrics, @_, undef if scalar @_ == 1;
            push @metrics, @_ if scalar @_ == 2;
            return 1;
        });

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
        @metrics = ();
        BOM::Event::Actions::Client::ready_for_authentication({
                loginid      => $test_client->loginid,
                applicant_id => $applicant_id,
            })->get;
        cmp_deeply + {@metrics},
            +{
            'event.onfido.ready_for_authentication.dispatch' => {tags => ['country:COL']},
            'event.onfido.check_applicant.dispatch'          => {tags => ['country:COL']},
            'event.onfido.check_applicant.failure'           => {tags => ['country:COL']},
            'event.onfido.ready_for_authentication.failure'  => {tags => ['country:COL']},
            },
            'Expected dd metrics';
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
        @metrics = ();
        BOM::Event::Actions::Client::client_verification({
                check_url => $check->{href},
            })->get;
        cmp_deeply + {@metrics},
            +{
            'event.onfido.client_verification.dispatch'         => undef,
            'event.onfido.client_verification.dob_not_reported' => {tags => ['check:clear', 'country:COL', 'report:clear']},
            'event.onfido.client_verification.not_verified'     => {tags => ['check:clear', 'country:COL', 'report:clear']},
            'event.onfido.client_verification.success'          => undef,
            },
            'Expected dd metrics';
    }
    "client verification emitted without exception";

    is $context->{brand_name}, $request->brand_name, 'brand name is correct';
    is $context->{language},   $request->language,   'language is correct';
    is $context->{app_id},     $request->app_id,     'app id is correct';

    request($another_req);

    $redis_r_write->del(BOM::Event::Actions::Client::ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY . $applicant_id);
    $redis_r_write->set(BOM::Event::Actions::Client::ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY . $applicant_id, ']non json format[');

    lives_ok {
        @metrics = ();
        BOM::Event::Actions::Client::client_verification({
                check_url => $check->{href},
            })->get;
        cmp_deeply + {@metrics},
            +{
            'event.onfido.client_verification.dispatch'         => undef,
            'event.onfido.client_verification.dob_not_reported' => {tags => ['check:clear', 'country:COL', 'report:clear']},
            'event.onfido.client_verification.not_verified'     => {tags => ['check:clear', 'country:COL', 'report:clear']},
            'event.onfido.client_verification.success'          => undef,
            },
            'Expected dd metrics';
    }
    "client verification emitted without exception";

    is $another_context->{brand_name}, $request->brand_name, 'brand name is correct';
    is $another_context->{language},   $request->language,   'language is correct';
    is $another_context->{app_id},     $request->app_id,     'app id is correct';

    $dog_mock->unmock_all;
};

$onfido_doc->unmock_all();

# construct a client that upload document itself, then test  client_verification, and see uploading documents
subtest 'client_verification after upload document himself' => sub {
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @metrics;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @metrics, @_;
            return 1;
        });

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
    $test_client2->place_of_birth('br');
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

    my $existing_onfido_docs = $dbic->run(
        fixup => sub {
            my $result = $_->prepare('select * from users.get_onfido_documents(?::BIGINT, ?::TEXT)');
            $result->execute($test_client2->binary_user_id, $applicant_id2);
            return $result->fetchall_hashref('id');
        });

    is_deeply($existing_onfido_docs, {}, 'at first no docs in db');

    lives_ok {
        @metrics = ();
        BOM::Event::Actions::Client::ready_for_authentication({
                loginid      => $test_client2->loginid,
                applicant_id => $applicant_id2,
            })->get;
        cmp_deeply + {@metrics},
            +{
            'event.onfido.ready_for_authentication.dispatch' => {tags => ['country:BRA']},
            'event.onfido.check_applicant.dispatch'          => {tags => ['country:BRA']},
            'event.onfido.check_applicant.success'           => {tags => ['country:BRA']},
            'event.onfido.ready_for_authentication.success'  => {tags => ['country:BRA']},
            },
            'Expected dd metrics';
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

    subtest 'Virtual account should get stopped out' => sub {
        my $exception = exception {
            BOM::Event::Actions::Client::sync_onfido_details({loginid => $vrtc_client->loginid})->get;
        };

        ok $exception =~ /Virtual account should not meddle with Onfido/, 'Expected exception has been thrown for virtual client';
    };

};

subtest 'signup event for track worker' => sub {

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
    my $handler = BOM::Event::Process->new(category => 'track')->actions->{signup};
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
            first_name      => $virtual_client2->first_name,
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
            lang          => 'ID',
        }
        },
        'properties is properly set for virtual account signup';
    test_segment_customer($customer, $virtual_client2, '', $virtual_client2->date_joined, 'virtual', 'labuan,svg');

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
            lang          => 'ID',
        }
        },
        'properties is set properly for real account signup event';

    $test_client2->set_default_account('EUR');

    ok $handler->($real_args)->get, 'successful signup track after setting currency';

    ($customer, %args) = @track_args;
    test_segment_customer($customer, $test_client2, 'EUR', $virtual_client2->date_joined, 'svg', 'labuan,svg');
};

subtest 'signup event' => sub {
    # Data sent for virtual signup should be loginid, country and landing company. Other values are not defined for virtual
    my $virtual_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code      => 'VRTC',
        email            => 'test23@bin.com',
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

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{signup};
    my $result  = $handler->($vr_args);
    ok $result, 'Success result';
    is_deeply \@emit_args,
        [
        'new_crypto_address',
        {
            loginid  => $virtual_client2->loginid,
            currency => $virtual_client2->currency
        }
        ],
        'new_crypto_address event is emitted';

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

    undef @emit_args;
    is exception { $handler->($real_args) }, undef, 'Event processed successfully';
    is_deeply \@emit_args,
        [
        'new_crypto_address',
        {
            loginid  => $test_client2->loginid,
            currency => $test_client2->currency
        },
        'verify_false_profile_info',
        {
            loginid    => $test_client2->loginid,
            first_name => $test_client2->first_name,
            last_name  => $test_client2->last_name,
        }
        ],
        'new_crypto_address and verify_false_profile_info events are emitted';
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
    my $handler = BOM::Event::Process->new(category => 'track')->actions->{signup};
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
            first_name      => $virtual_wallet_client->first_name,
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
            lang          => 'ID',
        }
        },
        'properties is properly set for wallet virtual account signup';
    test_segment_customer($customer, $virtual_wallet_client, '', $virtual_wallet_client->date_joined, 'virtual', 'labuan,svg');
};

subtest 'signup event email check for fraud ' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'fraud.email@gmail.com',
    });

    my $client1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'fraudemail@gmail.com',
    });
    my $email = $client->email;

    my $user = BOM::User->create(
        email    => $client->email,
        password => 'hello'
    );
    my $user1 = BOM::User->create(
        email    => $client1->email,
        password => 'hello'
    );
    $user->add_client($client);
    $user1->add_client($client1);

    my $cr_args = {
        loginid    => $client->loginid,
        new_user   => 1,
        properties => {
            type    => 'trading',
            subtype => 'real'
        }};

    # Preparing mocks magic
    my $mock_config = Test::MockModule->new('BOM::Config::Services');
    $mock_config->mock(is_enabled => 1);
    $mock_config->mock(
        config => {
            enabled => 1,
            host    => 'test',
            port    => 80,
        });

    my $fake_response    = Test::MockObject->new();
    my $fake_http_client = Test::MockObject->new();
    $fake_http_client->set_always(POST => Future->done($fake_response));

    my $mock_event = Test::MockModule->new('BOM::Event::Actions::Client');
    $mock_event->mock(_http => $fake_http_client);

    $fake_response->set_always(content => '{"result": {"status": "clear"}}');

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{signup};
    $handler->($cr_args)->get;

    delete $client->{status};    #clear status cache
    ok !$client->status->potential_fraud, 'No fraud status for clear result';

    $fake_response->set_always(
        content => '{"result": {"status": "suspected", "details": {"duplicate_emails":["fraud.email@gmail.com", "fraudemail@gmail.com"]}}}');

    $handler->($cr_args)->get;

    delete $client->{status};    #clear status cache
    ok $client->status->potential_fraud, 'has fraud status for suspected result';
    like $client->status->potential_fraud->{reason}, qr/fraud\.email\@gmail\.com/, 'Status contains first email in reason';
    like $client->status->potential_fraud->{reason}, qr/fraudemail\@gmail\.com/,   'Status contains second email in reason';

    delete $client1->{status};    #clear status cache
    ok $client1->status->potential_fraud, 'Second account also has fraud status for suspected result';
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

    undef $email_args;

    my $loginid = $test_client->loginid;

    my $call_args = {
        closing_reason    => 'There is no reason',
        loginid           => $loginid,
        loginids_disabled => [$loginid],
        loginids_failed   => [],
        email_consent     => 0
    };
    undef @emit_args;

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{account_closure};
    my $result         = $action_handler->($call_args);

    ok $result, 'Success result';
    is_deeply \@emit_args,
        [
        'account_deactivated',
        {
            loginid    => $loginid,
            properties => {
                name  => $test_client->first_name,
                brand => 'deriv'
            }}
        ],
        'account_deactivated event is emitted';

    $mock_client->unmock_all;
};

subtest 'account closure track' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    my $email_args;
    my $mock_client = Test::MockModule->new('BOM::Event::Actions::Client');

    undef @identify_args;
    undef @track_args;

    my $loginid = $test_client->loginid;

    my $call_args = {
        closing_reason    => 'There is no reason',
        loginid           => $loginid,
        loginids_disabled => [$loginid],
        loginids_failed   => [],
        email_consent     => 0
    };

    my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{account_closure};
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
            lang              => 'EN',
        },
        },
        'track context and properties are correct.';

    undef @identify_args;
    undef @track_args;

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);
    $result = $action_handler->($call_args)->get;
    isnt $result,               undef, 'Empty result';
    isnt scalar @identify_args, 0,     'No identify event is triggered when brand is binary';
    isnt scalar @track_args,    0,     'No track event is triggered when brand is binary';

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

    my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{transfer_between_accounts};
    ok $action_handler->($args)->get, 'transfer_between_accounts triggered successfully';
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
                lang          => 'ID',
                loginid       => $test_client->loginid,
            },
        },
        'identify context is properly set for transfer_between_account'
    );

    # Calling with `payment_agent_transfer` gateway should contain PaymentAgent fields
    $args->{properties}->{gateway_code} = 'payment_agent_transfer';

    ok $action_handler->($args)->get, 'transfer_between_accounts triggered successfully';
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
                lang               => 'ID',
                loginid            => $test_client->loginid,
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

    my $call_args = {
        loginid => $loginid,
        name    => [$loginid],
        scopes  => ['read', 'payment']};

    my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{api_token_created};
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
            lang    => 'ID',
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
    isnt $result,             undef, 'Empty result (not emitted)';
    is scalar @identify_args, 0,     'No identify event is triggered when brand is binary';
    isnt scalar @track_args,  0,     'No track event is triggered when brand is binary';
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

    my $call_args = {
        loginid => $loginid,
        name    => [$loginid],
        scopes  => ['read', 'payment']};

    my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{api_token_deleted};
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
            lang    => 'ID',
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
    isnt $result,             undef, 'Empty result (not emitted)';
    is scalar @identify_args, 0,     'No identify event is triggered when brand is binary';
    isnt scalar @track_args,  0,     'No track event is triggered when brand is binary';
};

sub test_segment_customer {
    my ($customer, $test_client, $currencies, $created_at, $landing_companies, $available_landing_companies) = @_;

    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is $customer->user_id, $test_client->binary_user_id, 'User id is binary user id';
    if ($test_client->is_virtual) {
        is_deeply $customer->traits,
            {
            'salutation' => $test_client->salutation,
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
            'salutation' => $test_client->salutation,
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

    my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{set_financial_assessment};
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
            brand   => 'deriv',
            lang    => 'ID',
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

    my $doc_expiration_date = Date::Utility->new()->plus_years(1)->date_yyyymmdd;
    $args = {
        document_type     => 'national_identity_card',
        document_format   => 'PNG',
        document_id       => '1234',
        expiration_date   => $doc_expiration_date,
        expected_checksum => '123456',
        page_type         => undef,
    };

    my $upload_info = start_document_upload($args, $test_client);

    $test_client->db->dbic->run(
        ping => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
        });

    undef @track_args;
    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{document_upload};
    $action_handler->({
            loginid => $test_client->loginid,
            file_id => $upload_info->{file_id}})->get;

    my ($customer, %args) = @track_args;
    is $args{event},                                    'document_upload',        'track event is document_upload';
    is $args{properties}->{document_type},              'national_identity_card', 'document type is correct';
    is $args{properties}->{uploaded_manually_by_staff}, 0,                        'uploaded_manually_by_staff is correct';
};

subtest 'edd document upload' => sub {

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );
    request($req);

    undef @track_args;

    $args = {
        document_type     => 'tax_return',
        document_format   => 'PNG',
        document_id       => '1234',
        expiration_date   => undef,
        expected_checksum => '123456',
        page_type         => undef,
    };

    my $upload_info = start_document_upload($args, $test_client);

    $test_client->db->dbic->run(
        ping => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
        });

    undef @track_args;
    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{document_upload};
    $action_handler->({
            loginid => $test_client->loginid,
            file_id => $upload_info->{file_id}})->get;

    my ($customer, %args) = @track_args;
    is $args{event},                                    'document_upload', 'track event is document_upload';
    is $args{properties}->{document_type},              'tax_return',      'document type is correct';
    is $args{properties}->{uploaded_manually_by_staff}, 0,                 'uploaded_manually_by_staff is correct';
};

subtest 'onfido resubmission' => sub {
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @metrics;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @metrics, @_, undef if scalar @_ == 1;
            push @metrics, @_ if scalar @_ == 2;

            return 1;
        });

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

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{ready_for_authentication};

    # For this test, we expect counter to be 0 due to empty checks
    $redis_write->set(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id, 0)->get;
    my $counter   = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get // 0;
    my $call_args = {
        loginid      => $test_client->loginid,
        applicant_id => $applicant_id
    };

    # For this test, we expect counter to be 0 due to empty checks
    @metrics = ();
    $action_handler->($call_args)->get;
    cmp_deeply + {@metrics},
        +{
        'event.onfido.ready_for_authentication.dispatch' => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.failure'  => {tags => ['country:COL']},
        },
        'Expected dd metrics';

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
    @metrics = ();
    $action_handler->($call_args)->get;

    cmp_deeply + {@metrics},
        +{
        'event.onfido.ready_for_authentication.dispatch'     => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.failure'      => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.resubmission' => {tags => ['country:COL']}
        },
        'Expected dd metrics';
    $counter_after = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    my $ttl = $redis_write->ttl(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter + 1, $counter_after, 'Resubmission Counter has been incremented by 1');

    my $age_below_eighteen_per_user = $redis_events->get(ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $test_client->binary_user_id)->get;
    ok(!$age_below_eighteen_per_user, 'Email blocker is gone');

    my $resubmission_context = $redis_write->get(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id)->get;
    ok($resubmission_context, 'Resubmission Context is set');

    # Resubmission flag should be off now and so we expect counter to remain the same
    @metrics = ();
    $action_handler->($call_args)->get;

    cmp_deeply + {@metrics},
        +{
        'event.onfido.ready_for_authentication.dispatch' => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.failure'  => {tags => ['country:COL']},
        },
        'Expected dd metrics';
    my $counter_after2 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter_after, $counter_after2, 'Resubmission Counter has not been incremented');

    # TTL should be the same after running it twice (roughly 30 days)
    # We, firstly, set a lower expire time
    $redis_write->expire(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id, 100)->get;
    my $lower_ttl = $redis_write->ttl(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($lower_ttl, 100, 'Resubmission Counter TTL has been set to 100');
    # Activate the flag and run again
    $test_client->status->set('allow_poi_resubmission', 'test staff', 'reason');
    @metrics = ();
    $action_handler->($call_args)->get;
    cmp_deeply + {@metrics},
        +{
        'event.onfido.ready_for_authentication.dispatch'     => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.failure'      => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.resubmission' => {tags => ['country:COL']}
        },
        'Expected dd metrics';

    # After running it twice TTL should be set to full time again (roughly 30 days, whatever $ttl is)
    my $ttl2 = $redis_write->ttl(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($ttl, $ttl2, 'Resubmission Counter TTL has been reset to its full time again');

    # For this one user's onfido daily counter will be too high, so the checkup won't be made
    my $counter_after3 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    $redis_events->set(ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id, 4)->get;
    $test_client->status->set('allow_poi_resubmission', 'test staff', 'reason');
    @metrics = ();
    $action_handler->($call_args)->get;
    cmp_deeply + {@metrics},
        +{
        'event.onfido.ready_for_authentication.dispatch'   => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.failure'    => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.user_limit' => {tags => ['country:COL']}
        },
        'Expected dd metrics';
    my $counter_after4 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter_after3, $counter_after4, 'Resubmission Counter has not been incremented due to user limits');

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update;
    my $onfido_request_limit = $app_config->system->onfido->global_daily_limit;
    # The last one, will be made upon the fact the whole company has its own onfido submit limit
    $redis_events->hset(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY, $onfido_request_limit)->get;
    $redis_events->set(ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id, 0)->get;
    $test_client->status->set('allow_poi_resubmission', 'test staff', 'reason');
    @metrics = ();
    $action_handler->($call_args)->get;

    cmp_deeply + {@metrics},
        +{
        'event.onfido.ready_for_authentication.dispatch'                   => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.failure'                    => {tags => ['country:COL']},
        'event.onfido.ready_for_authentication.global_daily_limit_reached' => undef,
        },
        'Expected dd metrics';

    my $counter_after5 = $redis_write->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $test_client->binary_user_id)->get;
    is($counter_after4, $counter_after5, 'Resubmission Counter has not been incremented due to global limits');
    $redis_events->hset(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY, 0)->get;
    $redis_events->set(ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id, 0)->get;

    subtest "client_verification on resubmission, verification failed" => sub {
        mailbox_clear();

        lives_ok {
            @metrics = ();
            BOM::Event::Actions::Client::client_verification({
                    check_url => $check->{href},
                })->get;
            cmp_deeply + {@metrics},
                +{
                'event.onfido.client_verification.dispatch'         => undef,
                'event.onfido.client_verification.not_verified'     => {tags => ['check:clear', 'country:COL', 'report:clear']},
                'event.onfido.client_verification.dob_not_reported' => {tags => ['check:clear', 'country:COL', 'report:clear']},
                'event.onfido.client_verification.success'          => undef,
                },
                'Expected dd metrics';
        }
        "client verification no exception";

        my $resubmission_context = $redis_write->get(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $test_client->binary_user_id)->get // 0;
        is($resubmission_context, 0, 'Resubmission Context is deleted');
    };

    subtest "_set_age_verification on resubmission, verification success" => sub {
        # As I don't have/know a valid payload from onfido, I'm going to test _set_age_verification instead
        undef @emit_args;

        my $req = BOM::Platform::Context::Request->new(language => 'EN');
        request($req);

        $test_client->status->setnx('poi_name_mismatch', 'test', 'test');
        BOM::Event::Actions::Common::set_age_verification($test_client, 'Onfido');
        ok !$test_client->status->age_verification, 'Could not set age verification: poi name mismatch';

        $test_client->status->clear_poi_name_mismatch;
        BOM::Event::Actions::Common::set_age_verification($test_client, 'Onfido');
        ok $test_client->status->age_verification, 'Client is age verified';
        is_deeply \@emit_args,
            [
            'age_verified',
            {
                loginid    => $test_client->loginid,
                properties => {
                    contact_url   => 'https://deriv.com/en/contact-us',
                    poi_url       => 'https://app.deriv.com/account/proof-of-identity?lang=en',
                    live_chat_url => 'https://deriv.com/en/?is_livechat_open=true',
                    email         => $test_client->email,
                    name          => $test_client->first_name,
                    website_name  => 'Deriv.com'
                }}
            ],
            'Age verified client';

        undef @emit_args;
    };

    $mock_client->unmock_all;
    $mock_onfido->unmock_all;
    $mock_redis->unmock_all;
    $dog_mock->unmock_all;
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
        })->get;

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
        payment_type      => 'EWallet',
        transaction_id    => 123,
        payment_id        => 456,
        payment_processor => 'xyz',
    };

    BOM::Event::Actions::Client::payment_deposit($event_args)->get;

    $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
    ok !$test_client->status->personal_details_locked, 'personal details are not locked - non-card payment method was used';

    $event_args->{payment_type} = 'CreditCard';

    BOM::Event::Actions::Client::payment_deposit($event_args)->get;

    $test_client = BOM::User::Client->new({loginid => $test_client->loginid});

    ok $test_client->status->personal_details_locked, 'personal details are locked when a card payment method is used';
    is $test_client->status->personal_details_locked->{reason}, "A card deposit is made via xyz with ref. id: 123";
    $test_client->status->clear_personal_details_locked;
    $test_client->save;
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
        } keys $test_client->documents->provider_types->{onfido}->%*
    ];

    $test_client->status->clear_allow_poi_resubmission;
    $test_client->status->clear_allow_poa_resubmission;

    foreach my $args ($document_types->@*) {
        subtest $args->{document_type} => sub {
            my $upload_info = start_document_upload($args, $test_client);

            $test_client->status->set('allow_poi_resubmission', 'test', 'test');
            $test_client->status->setnx('allow_poa_resubmission', 'test', 'test');
            $test_client->db->dbic->run(
                ping => sub {
                    $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
                });

            my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{document_upload};
            $action_handler->({
                    loginid => $test_client->loginid,
                    file_id => $upload_info->{file_id}})->get;

            ok !$test_client->status->_get('allow_poi_resubmission'), 'POI flag successfully gone';
            ok $test_client->status->_get('allow_poa_resubmission'),  'POI upload should not disable the POA flag';
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
        } $test_client->documents->poa_types->@*
    ];

    $test_client->status->clear_allow_poi_resubmission;
    $test_client->status->clear_allow_poa_resubmission;

    foreach my $args ($document_types->@*) {
        subtest $args->{document_type} => sub {
            my $upload_info = start_document_upload($args, $test_client);

            $test_client->status->setnx('allow_poi_resubmission', 'test', 'test');
            $test_client->status->set('allow_poa_resubmission', 'test', 'test');
            $test_client->db->dbic->run(
                ping => sub {
                    $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
                });

            my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{document_upload};
            $action_handler->({
                    loginid => $test_client->loginid,
                    file_id => $upload_info->{file_id}})->get;

            ok $test_client->status->_get('allow_poi_resubmission'),  'POA upload should not disable the POI flag';
            ok !$test_client->status->_get('allow_poa_resubmission'), 'POA flag successfully gone';
        };
    }
};

subtest 'account_reactivated' => sub {
    my @email_args;
    my $mock_event = Test::MockModule->new('BOM::Event::Actions::Client');

    my $needs_verification = 0;
    my $mock_client        = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine('needs_poi_verification', sub { return $needs_verification; });

    my $social_responsibility = 0;
    my $mock_landing_company  = Test::MockModule->new('LandingCompany');
    $mock_landing_company->redefine('social_responsibility_check', sub { return $social_responsibility; });

    my $call_args = {
        loginid => $test_client->loginid,
        reason  => 'test reason'
    };
    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{account_reactivated};

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    my $brand = request->brand;
    undef @emit_args;

    is exception { $handler->($call_args) }, undef, 'Event processed successfully';
    $needs_verification = 1;
    mailbox_clear();

    is exception { $handler->($call_args) }, undef, 'Event processed successfully';
    $msg = mailbox_search(
        subject => qr/has been reactivated/,
    );
    ok !$msg, 'No SR email is sent';

    $social_responsibility = 'required';
    mailbox_clear();

    is exception { $handler->($call_args) }, undef, 'Event processed successfully';
    $msg = mailbox_search(subject => qr/has been reactivated/);
    ok $msg, 'Email to SR team is found';
    is_deeply $msg->{to}, [request->brand->emails('social_responsibility')], 'SR email address is correct';
};

subtest 'account_reactivated for track worker' => sub {
    my $needs_verification = 0;
    my $mock_client        = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine('needs_poi_verification', sub { return $needs_verification; });
    request(
        BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'ES',
            app_id     => $app_id,
        ));
    my $brand = request->brand;

    my $handler = BOM::Event::Process->new(category => 'track')->actions->{account_reactivated};
    undef @track_args;
    undef @emit_args;

    my $call_args = {
        loginid => $test_client->loginid,
        reason  => 'test reason'
    };
    is exception { $handler->($call_args)->get }, undef, 'Event processed successfully';
    my (undef, %args) = @track_args;

    cmp_deeply(
        \%args,
        {
            context    => ignore(),
            event      => 'account_reactivated',
            properties => {
                first_name       => $test_client->first_name,
                loginid          => $test_client->loginid,
                brand            => 'deriv',
                profile_url      => $brand->profile_url,
                resp_trading_url => $brand->responsible_trading_url({language => uc(request->language // 'es')}),
                live_chat_url    => $brand->live_chat_url({language => uc(request->language // 'es')}),
                needs_poi        => bool(0),
                lang             => 'ES',
                new_campaign     => 1,
            }
        },
        'track event params'
    );
};

subtest 'withdrawal_limit_reached' => sub {
    my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    my $is_poa_pending;
    $documents_mock->mock(
        'uploaded',
        sub {
            my ($self) = @_;

            $self->_clear_uploaded;

            return {
                proof_of_address => {
                    is_pending => $is_poa_pending,
                    documents  => {},
                }};
        });

    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $fully_authenticated;

    $client_mock->mock(
        'fully_authenticated',
        sub {
            return $fully_authenticated;
        });

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $handler   = BOM::Event::Process->new(category => 'generic')->actions->{withdrawal_limit_reached};
    my $call_args = {
        loginid => $test_client->loginid,
    };

    throws_ok(
        sub {
            $handler->()->get;
        },
        qr/\bClient login ID was not given\b/,
        'Expected exception thrown, clientid was not given'
    );

    throws_ok(
        sub {
            $handler->({loginid => 'CR0'})->get;
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
    $documents_mock->unmock_all;
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

subtest 'EDD email notification' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    mailbox_clear();
    BOM::Event::Actions::Client::_send_complaince_email_pow_uploaded($test_client)->get;

    my $msg = mailbox_search(subject => qr/New uploaded EDD document for/);
    ok $msg, 'email sent';
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

    my $handler   = BOM::Event::Process->new(category => 'generic')->actions->{verify_address};
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
        is $args{event},                  $event,                             "$event event name";
        is $args{properties}{first_name}, $payload->{properties}{first_name}, "$event properties";
    }

};

subtest 'request_change_email' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            first_name => 'Aname',
            email      => 'any_email@anywhere.com',
            language   => 'EN',
        }};

    my $handler = BOM::Event::Process::->new(category => 'track')->actions->{request_change_email};
    my $result  = $handler->($args)->get;
    ok $result, 'OK result';
    is scalar @track_args, 7, 'OK event';
    my ($customer, %args) = @track_args;
    is $args{event},                  'request_change_email',          "event name";
    is $args{properties}{first_name}, $args->{properties}{first_name}, "event properties";
};

subtest 'verify_change_email' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            first_name => 'Aname',
            email      => 'any_email@anywhere.com',
            language   => 'EN',
        }};

    my $handler = BOM::Event::Process::->new(category => 'track')->actions->{verify_change_email};
    my $result  = $handler->($args)->get;
    ok $result, 'OK result';
    my ($customer, %args) = @track_args;
    is $args{event},                  'verify_change_email',           "event event name";
    is $args{properties}{first_name}, $args->{properties}{first_name}, "event properties";
    is scalar @track_args,            7,                               'OK event';
};

subtest 'confirm_change_email' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            first_name => 'Aname',
            email      => 'any_email@anywhere.com',
            language   => 'EN',
        }};

    my $handler = BOM::Event::Process::->new(category => 'track')->actions->{confirm_change_email};
    my $result  = $handler->($args)->get;
    ok $result, 'OK result';
    my ($customer, %args) = @track_args;
    is $args{event},                  'confirm_change_email',          "event name";
    is $args{properties}{first_name}, $args->{properties}{first_name}, "event properties";
    is scalar @track_args,            7,                               'OK event';
};

subtest 'crypto_withdrawal_email event' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client->email('test@deriv.com');
    $client->first_name('Jane');
    $client->last_name('Doe');
    $client->salutation('MR');
    $client->save;

    my $user = BOM::User->create(
        email          => $client->email,
        password       => "1234",
        email_verified => 1,
    )->add_client($client);

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    undef @track_args;

    BOM::Event::Actions::Client::crypto_withdrawal_email({
            loginid          => $client->loginid,
            amount           => '2',
            currency         => 'ETH',
            transaction_hash => '0xjkdf483jfh834ekjh834kdk48',
            transaction_url  => 'https://sepolia.etherscan.io/tx/0xjkdf483jfh834ekjh834kdk48',
            live_chat_url    => 'https://deriv.com/en/?is_livechat_open=true',
            title            => 'Your ETH withdrawal is successful',
        })->get;

    my ($customer, %args) = @track_args;

    is $args{event}, 'crypto_withdrawal_email', "got correct event name";

    cmp_deeply $args{properties},
        {
        'loginid'          => $client->loginid,
        'brand'            => 'deriv',
        'currency'         => 'ETH',
        'lang'             => 'EN',
        'amount'           => '2',
        'transaction_hash' => '0xjkdf483jfh834ekjh834kdk48',
        'transaction_url'  => 'https://sepolia.etherscan.io/tx/0xjkdf483jfh834ekjh834kdk48',
        'live_chat_url'    => 'https://deriv.com/en/?is_livechat_open=true',
        'title'            => 'Your ETH withdrawal is successful',
        },
        'event properties are ok';

    is $args{properties}->{loginid}, $client->loginid, "got correct customer loginid";
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
};

subtest 'deposit limits breached' => sub {
    my $cumulative_total = 0;

    my $df_mock = Test::MockModule->new('BOM::Database::DataMapper::Payment::DoughFlow');
    $df_mock->mock(
        'payment_type_cumulative_total',
        sub {
            return $cumulative_total;
        });

    # note this test is based on the default configuration
    # assume: za -> CreditCard -> limit: 500, days: 7
    $test_client->status->clear_allow_document_upload;
    $test_client->status->clear_age_verification;

    my $event_args = {
        loginid          => $test_client->loginid,
        is_first_deposit => 0,
        payment_type     => 'EWallet',
        transaction_id   => 123,
        payment_id       => 456,
        amount           => 100,
    };

    $cumulative_total = 100;

    BOM::Event::Actions::Client::payment_deposit($event_args)->get();

    ok !$test_client->status->allow_document_upload, 'allow_document_upload not triggered for ewallet deposit';

    $event_args->{payment_type} = 'CreditCard';

    BOM::Event::Actions::Client::payment_deposit($event_args)->get();

    ok !$test_client->status->allow_document_upload, 'allow_document_upload not triggered for credit card deposit < 500';

    ok !$test_client->status->df_deposit_requires_poi, 'df_deposit_requires_poi not triggered for credit card deposit < 500';

    $event_args->{amount} = 500;

    $cumulative_total = 500;

    BOM::Event::Actions::Client::payment_deposit($event_args)->get();

    ok !$test_client->status->allow_document_upload, 'allow_document_upload not triggered for credit card deposit >= 500 (but the country!)';

    ok !$test_client->status->df_deposit_requires_poi, 'df_deposit_requires_poi not triggered for credit card deposit >= 500 (but the country!)';

    $test_client->residence('za');
    $test_client->save;

    $test_client->status->set('age_verification', 'test', 'test');
    BOM::Event::Actions::Client::payment_deposit($event_args)->get();
    ok !$test_client->status->allow_document_upload,   'allow_document_upload not triggered for credit card deposit >= 500 (age verified)';
    ok !$test_client->status->df_deposit_requires_poi, 'df_deposit_requires_poi not triggered for credit card deposit >= 500 (age verified)';

    $test_client->status->clear_age_verification;
    BOM::Event::Actions::Client::payment_deposit($event_args)->get();

    $test_client->status->_build_all;
    ok $test_client->status->allow_document_upload,   'allow_document_upload triggered for credit card deposit >= 500';
    ok $test_client->status->df_deposit_requires_poi, 'df_deposit_requires_poi triggered for credit card deposit >= 500';

    # so far all the tests have been in USD
    subtest 'exchange rate' => sub {
        $test_sibling->residence('za');
        $test_sibling->save;

        $test_sibling->status->clear_df_deposit_requires_poi;
        $test_sibling->status->clear_allow_document_upload;
        $test_sibling->status->_build_all;
        $event_args->{loginid} = $test_sibling->loginid;

        populate_exchange_rates({LTC => 100});
        $event_args->{currency} = 'LTC';
        $event_args->{amount}   = 1;
        $cumulative_total       = 1;

        BOM::Event::Actions::Client::payment_deposit($event_args)->get();

        ok !$test_sibling->status->allow_document_upload,   'allow_document_upload not triggered yet';
        ok !$test_sibling->status->df_deposit_requires_poi, 'df_deposit_requires_poi not triggered yet';

        populate_exchange_rates({LTC => 70});
        $event_args->{amount} = 2;
        $cumulative_total = 3;

        BOM::Event::Actions::Client::payment_deposit($event_args)->get();

        ok !$test_sibling->status->allow_document_upload,   'allow_document_upload not triggered yet';
        ok !$test_sibling->status->df_deposit_requires_poi, 'df_deposit_requires_poi not triggered yet';

        populate_exchange_rates({LTC => 125});
        $event_args->{amount} = 1;
        $cumulative_total = 4;

        BOM::Event::Actions::Client::payment_deposit($event_args)->get();

        $test_sibling->status->_build_all;
        ok $test_sibling->status->allow_document_upload,   'allow_document_upload triggered';
        ok $test_sibling->status->df_deposit_requires_poi, 'df_deposit_requires_poi triggered';

        subtest 'no exchange rate available' => sub {
            my $cli_mock = Test::MockModule->new('BOM::Platform::Client::AntiFraud');
            $cli_mock->mock(
                'in_usd',
                sub {
                    die 'test';
                });
            my $loginid = $test_sibling->loginid;

            $log->clear();
            BOM::Event::Actions::Client::payment_deposit($event_args)->get();

            $log->contains_ok(qr/Failed to check for deposit limits of the client $loginid: test/, 'expecte fail message logged');

            $cli_mock->unmock_all;
        }
    };

    $df_mock->unmock_all;
};
subtest 'new account opening' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $param = {
        event            => 'account_opening_new',
        type             => 'event',
        verification_url => 'https://verification_url.com/',
        live_chat_url    => 'https://www.binary.com/en/contact.html?is_livechat_open=true',
        code             => 'CODE',
        language         => 'EN',
        email            => $test_client->email,
    };

    my $handler = BOM::Event::Process::->new(category => 'track')->actions->{account_opening_new};
    my $result  = $handler->($param)->get;
    ok $result, 'Success result';
    my ($customer, %args) = @track_args;
    is $args{event}, 'account_opening_new', "got account_opening_new";
    cmp_deeply $args{properties},
        {
        brand            => 'deriv',
        lang             => 'EN',
        verification_url => 'https://verification_url.com/',
        live_chat_url    => 'https://www.binary.com/en/contact.html?is_livechat_open=true',
        code             => 'CODE',
        email            => $test_client->email,
        },
        'event properties are ok';
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
};

my $pa_test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_test_client->set_default_account('USD');
$pa_test_client->payment_agent({
    payment_agent_name    => "Joe",
    email                 => 'joe@example.com',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    currency_code         => 'USD',
    status                => 'authorized',
});
$pa_test_client->save;
$pa_test_client->get_payment_agent->set_countries(['id']);

subtest 'pa transfer confirm' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $param = {
        'loginid'           => $test_client->loginid,
        'pa_email'          => $pa_test_client->email,
        'pa_last_name'      => 'pItT',
        'website_name'      => undef,
        'client_loginid'    => 'CR10005',
        'client_last_name'  => 'pItT',
        'title'             => 'We\'ve completed a transfer',
        'pa_first_name'     => 'bRaD',
        'client_salutation' => 'MR',
        'client_first_name' => 'bRaD',
        'pa_loginid'        => 'CR10004',
        'name'              => 'bRaD',
        'client_name'       => 'bRaD pItT',
        'pa_salutation'     => 'MR',
        'amount'            => 10,
        'pa_name'           => 'Xoe',
        'currency'          => 'USD'
    };

    my $handler = BOM::Event::Process::->new(category => 'generic')->actions->{pa_transfer_confirm};
    my $result  = $handler->($param)->get;
    ok $result, 'Success result';

    my ($customer, %r_args) = @track_args;

    is $r_args{event}, 'pa_transfer_confirm', "Event=pa_transfer_confirm";

    cmp_deeply $r_args{properties},
        {
        amount        => '10',
        brand         => 'deriv',
        client_name   => 'bRaD pItT',
        loginid       => 'CR10005',
        currency      => 'USD',
        lang          => 'ID',
        loginid       => $test_client->loginid,
        email         => $test_client->email,
        pa_first_name => 'bRaD',
        pa_last_name  => 'pItT',
        pa_name       => 'Xoe',
        pa_loginid    => 'CR10004',
        },
        'event properties are ok';

    is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";
};

subtest 'pa withdraw confirm' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );

    request($req);
    undef @identify_args;
    undef @track_args;

    my $param = {
        'loginid'           => $test_client->loginid,
        'email'             => $test_client->email,
        'pa_last_name'      => 'pItT',
        'website_name'      => undef,
        'client_loginid'    => 'CR00007',
        'client_last_name'  => 'pItT',
        'title'             => 'We\'ve completed a transfer',
        'pa_first_name'     => 'bRaD',
        'client_salutation' => 'MR',
        'client_first_name' => 'bRaD',
        'pa_loginid'        => $pa_test_client->loginid,
        'name'              => 'bRaD',
        'client_name'       => 'bRaD pItT',
        'pa_salutation'     => 'MR',
        'amount'            => 10,
        'pa_name'           => 'Xoe',
        'currency'          => 'USD'
    };

    my $handler = BOM::Event::Process::->new(category => 'generic')->actions->{pa_withdraw_confirm};
    my $result  = $handler->($param)->get;
    ok $result, 'Success result';

    my ($customer, %r_args) = @track_args;

    is $r_args{event}, 'pa_withdraw_confirm', "Event=pa_withdraw_confirm";
    cmp_deeply $r_args{properties},
        {
        email          => $test_client->email,
        brand          => 'deriv',
        client_name    => 'bRaD pItT',
        client_loginid => 'CR00007',
        currency       => 'USD',
        lang           => 'ID',
        loginid        => $test_client->loginid,
        email          => $test_client->email,
        pa_name        => 'Xoe',
        amount         => '10',
        pa_loginid     => $pa_test_client->loginid,
        pa_first_name  => $pa_test_client->first_name,
        pa_last_name   => $pa_test_client->last_name,
        },
        'event properties are ok';

    is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";
};

subtest 'underage_account_closed' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    undef @track_args;

    my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{underage_account_closed};

    $action_handler->({
            loginid    => $client->loginid,
            properties => {
                tnc_approval => 'https://deriv.com/en/terms-and-conditions',
            }})->get;
    my ($customer, %returned_args) = @track_args;

    is $returned_args{event},                 'underage_account_closed', 'track event name is set correctly';
    is $returned_args{properties}->{loginid}, $client->loginid,          "got correct customer loginid";
};

subtest 'Underage detection' => sub {
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @metrics;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @metrics, @_ if scalar @_ == 2;
            push @metrics, @_, undef if scalar @_ == 1;

            return 1;
        });
    my $mocked_actions = Test::MockModule->new('BOM::Event::Actions::Client');
    $mocked_actions->mock(
        '_restore_request',
        sub {
            return Future->done(1);
        });

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );

    request($req);
    my $mocked_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions      = {};
    $mocked_emitter->mock(
        'emit',
        sub {
            my $args = {@_};

            $emissions = {$emissions->%*, $args->%*};

            return undef;
        });

    my $vrtc_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => 'vrtc+test1@bin.com',
    });

    $test_client->user->add_client($vrtc_client);

    my $brand  = request->brand;
    my $params = {
        language => uc($test_client->user->preferred_language // request->language // 'en'),
    };
    my $trading_platform_loginids = {};
    my $underage_result;
    my $reported_dob;
    my $report_result;
    my $reported_first_name;
    my $reported_last_name;

    my $mocked_user = Test::MockModule->new('BOM::User');
    $mocked_user->mock(
        'get_trading_platform_loginids',
        sub {
            my (undef, $platform, $account_type) = @_;
            my $loginids = $trading_platform_loginids->{$platform}->{$account_type} // [];
            return $loginids->@*;
        });

    my $mocked_onfido = Test::MockModule->new('BOM::User::Onfido');
    $mocked_onfido->mock(
        'get_all_onfido_reports',
        sub {
            my $reports = +{
                test => {
                    api_name   => 'document',
                    properties => encode_json_utf8({
                            date_of_birth => $reported_dob,
                            first_name    => $reported_first_name,
                            last_name     => $reported_last_name,
                        }
                    ),
                },
            };

            return $reports;
        });

    my $mocked_report = Test::MockModule->new('WebService::Async::Onfido::Report');
    $mocked_report->mock(
        'new' => sub {
            my $self = shift, my %data = @_;
            $data{result}                                                                     = $report_result;
            $data{properties}->{date_of_birth}                                                = $reported_dob;
            $data{properties}->{first_name}                                                   = $reported_first_name;
            $data{properties}->{last_name}                                                    = $reported_last_name;
            $data{breakdown}->{age_validation}->{breakdown}->{minimum_accepted_age}->{result} = $underage_result;
            $mocked_report->original('new')->($self, %data);
        });

    subtest 'underage result is consider' => sub {
        $trading_platform_loginids = {};
        $emissions                 = {};
        $underage_result           = 'consider';
        $reported_dob              = undef;
        $report_result             = 'consider';

        $vrtc_client->status->clear_disabled();
        $vrtc_client->status->_build_all();
        $test_client->status->clear_disabled();
        $test_client->status->clear_age_verification();
        $test_client->status->clear_poi_name_mismatch();
        $test_client->status->_build_all();
        mailbox_clear();

        lives_ok {
            @metrics = ();
            BOM::Event::Actions::Client::client_verification({
                    check_url => $check->{href},
                })->get;
            cmp_deeply + {@metrics},
                +{
                'event.onfido.client_verification.dispatch'          => undef,
                'event.onfido.client_verification.not_verified'      => {tags => ['check:clear', 'country:COL', 'report:consider']},
                'event.onfido.client_verification.underage_detected' => {tags => ['check:clear', 'country:COL', 'report:consider']},
                'event.onfido.client_verification.success'           => undef,
                },
                'Expected dd metrics';
        }
        'the event made it alive!';

        cmp_deeply $vrtc_client->status->disabled,
            +{
            last_modified_date => re('\w'),
            status_code        => 'disabled',
            staff_name         => 'system',
            reason             => 'Onfido - client is underage',
            },
            'Expected disabled status';

        cmp_deeply $test_client->status->disabled,
            +{
            last_modified_date => re('\w'),
            status_code        => 'disabled',
            staff_name         => 'system',
            reason             => 'Onfido - client is underage',
            },
            'Expected disabled status';

        cmp_deeply $emissions->{underage_account_closed},
            {
            loginid    => $test_client->loginid,
            properties => {
                tnc_approval => $brand->tnc_approval_url($params),
            }
            },
            'underage_account_closed event emitted';

        ok !$test_client->status->age_verification, 'Not age verified';

        my $msg = mailbox_search(subject => qr/Underage client detection/);

        ok !$msg, 'underage email not sent to CS';

        subtest 'it has a mt5 real account' => sub {
            $trading_platform_loginids = {
                mt5 => {
                    real => [qw/MTR9009 MTR90000/],
                    demo => [qw/MTD90000/]
                },
            };

            $underage_result = 'consider';
            $reported_dob    = undef;
            $report_result   = 'consider';
            $emissions       = {};

            $vrtc_client->status->clear_disabled();
            $vrtc_client->status->_build_all();
            $test_client->status->clear_disabled();
            $test_client->status->clear_age_verification();
            $test_client->status->clear_poi_name_mismatch();
            $test_client->status->_build_all();
            mailbox_clear();

            lives_ok {
                @metrics = ();
                BOM::Event::Actions::Client::client_verification({
                        check_url => $check->{href},
                    })->get;
                cmp_deeply + {@metrics},
                    +{
                    'event.onfido.client_verification.dispatch'          => undef,
                    'event.onfido.client_verification.not_verified'      => {tags => ['check:clear', 'country:COL', 'report:consider']},
                    'event.onfido.client_verification.underage_detected' => {tags => ['check:clear', 'country:COL', 'report:consider']},
                    'event.onfido.client_verification.success'           => undef,
                    },
                    'Expected dd metrics';
            }
            'the event made it alive!';

            ok !$vrtc_client->status->disabled, 'Disabled status not set (mt5 real)';

            ok !$test_client->status->disabled, 'Disabled status not set (mt5 real)';

            ok !$test_client->status->age_verification, 'Not age verified';

            ok !$emissions->{underage_account_closed}, 'underage_account_closed not event emitted';

            my $msg = mailbox_search(subject => qr/Underage client detection/);
            ok $msg, 'underage email sent to CS';
            ok $msg->{body} =~ /The client posseses the following MT5 loginids/, 'MT5 loginds detected';
            ok $msg->{body} =~ /\bMTR9009\b/,                                    'Real MT5 loginid reported';
            ok $msg->{body} =~ /\bMTR90000\b/,                                   'Real MT5 loginid reported';
            ok $msg->{body} !~ /\bMTD90000\b/,                                   'Demo MT5 loginid not reported';
            cmp_deeply $msg->{to}, [$brand->emails('authentications')], 'Expected to email address';
        };

        subtest 'it has a mt5 demo account' => sub {
            $emissions                 = {};
            $trading_platform_loginids = {
                mt5 => {
                    demo => [qw/MTD9009/],
                },
            };

            $underage_result = 'consider';
            $reported_dob    = undef;
            $report_result   = 'consider';

            $vrtc_client->status->clear_disabled();
            $vrtc_client->status->_build_all();
            $test_client->status->clear_disabled();
            $test_client->status->clear_age_verification();
            $test_client->status->clear_poi_name_mismatch();
            $test_client->status->_build_all();
            mailbox_clear();

            lives_ok {
                @metrics = ();
                BOM::Event::Actions::Client::client_verification({
                        check_url => $check->{href},
                    })->get;
                cmp_deeply + {@metrics},
                    +{
                    'event.onfido.client_verification.dispatch'          => undef,
                    'event.onfido.client_verification.not_verified'      => {tags => ['check:clear', 'country:COL', 'report:consider']},
                    'event.onfido.client_verification.underage_detected' => {tags => ['check:clear', 'country:COL', 'report:consider']},
                    'event.onfido.client_verification.success'           => undef,
                    },
                    'Expected dd metrics';
            }
            'the event made it alive!';

            ok $vrtc_client->status->disabled, 'Disabled status set (mt5 demo)';

            ok $test_client->status->disabled, 'Disabled status set (mt5 demo)';

            ok !$test_client->status->age_verification, 'Not age verified';

            cmp_deeply $emissions->{underage_account_closed},
                {
                loginid    => $test_client->loginid,
                properties => {
                    tnc_approval => $brand->tnc_approval_url($params),
                }
                },
                'underage_account_closed event emitted';

            my $msg = mailbox_search(subject => qr/Underage client detection/);

            ok !$msg, 'underage email not sent CS';
        };
    };

    subtest 'underage result is rejected' => sub {
        $trading_platform_loginids = {};
        $underage_result           = 'rejected';
        $reported_dob              = undef;
        $report_result             = 'rejected';
        $emissions                 = {};

        $vrtc_client->status->clear_disabled();
        $vrtc_client->status->_build_all();
        $test_client->status->clear_disabled();
        $test_client->status->clear_poi_name_mismatch();
        $test_client->status->clear_age_verification();
        $test_client->status->_build_all();
        mailbox_clear();

        lives_ok {
            @metrics = ();
            BOM::Event::Actions::Client::client_verification({
                    check_url => $check->{href},
                })->get;
            cmp_deeply + {@metrics},
                +{
                'event.onfido.client_verification.dispatch'          => undef,
                'event.onfido.client_verification.not_verified'      => {tags => ['check:clear', 'country:COL', 'report:rejected']},
                'event.onfido.client_verification.underage_detected' => {tags => ['check:clear', 'country:COL', 'report:rejected']},
                'event.onfido.client_verification.success'           => undef,
                },
                'Expected dd metrics';
        }
        'the event made it alive!';

        cmp_deeply $emissions->{underage_account_closed},
            {
            loginid    => $test_client->loginid,
            properties => {
                tnc_approval => $brand->tnc_approval_url($params),
            }
            },
            'underage_account_closed event emitted';

        cmp_deeply $vrtc_client->status->disabled,
            +{
            last_modified_date => re('\w'),
            status_code        => 'disabled',
            staff_name         => 'system',
            reason             => 'Onfido - client is underage',
            },
            'Expected disabled status';

        cmp_deeply $test_client->status->disabled,
            +{
            last_modified_date => re('\w'),
            status_code        => 'disabled',
            staff_name         => 'system',
            reason             => 'Onfido - client is underage',
            },
            'Expected disabled status';

        ok !$test_client->status->age_verification, 'Not age verified';

        my $msg = mailbox_search(subject => qr/Underage client detection/);

        ok !$msg, 'underage email not sent to CS';

        subtest 'it has a dxtrader real account' => sub {
            $emissions                 = {};
            $trading_platform_loginids = {
                dxtrader => {
                    real => [qw/DXR9009/],
                    demo => [qw/DXD90000/],
                },
            };

            $underage_result = 'rejected';
            $reported_dob    = undef;
            $report_result   = 'rejected';

            $vrtc_client->status->clear_disabled();
            $vrtc_client->status->_build_all();
            $test_client->status->clear_disabled();
            $test_client->status->clear_age_verification();
            $test_client->status->clear_poi_name_mismatch();
            $test_client->status->_build_all();
            mailbox_clear();

            lives_ok {
                BOM::Event::Actions::Client::client_verification({
                        check_url => $check->{href},
                    })->get;
            }
            'the event made it alive!';

            ok !$emissions->{underage_account_closed}, 'underage_account_closed event emitted';

            ok !$vrtc_client->status->disabled, 'Disabled status not set (dxtrader real)';

            ok !$test_client->status->disabled, 'Disabled status not set (dxtrader real)';

            ok !$test_client->status->age_verification, 'Not age verified';

            my $msg = mailbox_search(subject => qr/Underage client detection/);
            ok $msg, 'underage email sent to CS';
            ok $msg->{body} =~ /The client posseses the following Deriv X loginids/, 'DX loginds detected';
            ok $msg->{body} =~ /\bDXR9009\b/,                                        'Real DX loginid reported';
            ok $msg->{body} !~ /\bDXD90000\b/,                                       'Demo DX loginid not reported';
            cmp_deeply $msg->{to}, [$brand->emails('authentications')], 'Expected to email address';
        };

        subtest 'it has a dxtrader demo account' => sub {
            $trading_platform_loginids = {
                dxtrader => {
                    demo => [qw/DXD9009/],
                },
            };

            $underage_result = 'rejected';
            $reported_dob    = undef;
            $report_result   = 'rejected';
            $emissions       = {};

            $vrtc_client->status->clear_disabled();
            $vrtc_client->status->_build_all();
            $test_client->status->clear_disabled();
            $test_client->status->clear_age_verification();
            $test_client->status->clear_poi_name_mismatch();
            $test_client->status->_build_all();
            mailbox_clear();

            lives_ok {
                @metrics = ();
                BOM::Event::Actions::Client::client_verification({
                        check_url => $check->{href},
                    })->get;
                cmp_deeply + {@metrics},
                    +{
                    'event.onfido.client_verification.dispatch'          => undef,
                    'event.onfido.client_verification.not_verified'      => {tags => ['check:clear', 'country:COL', 'report:rejected']},
                    'event.onfido.client_verification.underage_detected' => {tags => ['check:clear', 'country:COL', 'report:rejected']},
                    'event.onfido.client_verification.success'           => undef,
                    },
                    'Expected dd metrics';
            }
            'the event made it alive!';

            cmp_deeply $emissions->{underage_account_closed},
                {
                loginid    => $test_client->loginid,
                properties => {
                    tnc_approval => $brand->tnc_approval_url($params),
                }
                },
                'underage_account_closed event emitted';

            ok $vrtc_client->status->disabled, 'Disabled status set (dxtrader demo)';

            ok $test_client->status->disabled, 'Disabled status set (dxtrader demo)';

            ok !$test_client->status->age_verification, 'Not age verified';

            my $msg = mailbox_search(subject => qr/Underage client detection/);

            ok !$msg, 'underage email not sent to cs';
        };
    };

    subtest 'underage result is clear' => sub {
        $trading_platform_loginids = {};
        $underage_result           = 'clear';
        $reported_dob              = '1989-10-10';
        $report_result             = 'clear';
        $emissions                 = {};
        $reported_first_name       = $test_client->first_name;
        $reported_last_name        = $test_client->last_name;

        $vrtc_client->status->clear_disabled();
        $vrtc_client->status->_build_all();
        $test_client->status->clear_disabled();
        $test_client->status->clear_age_verification();
        $test_client->status->clear_poi_name_mismatch();
        $test_client->status->_build_all();
        mailbox_clear();

        lives_ok {
            @metrics = ();
            BOM::Event::Actions::Client::client_verification({
                    check_url => $check->{href},
                })->get;
            cmp_deeply + {@metrics},
                +{
                'event.onfido.client_verification.dispatch'         => undef,
                'event.onfido.client_verification.age_verification' => {tags => ['check:clear', 'country:COL', 'report:clear']},
                'event.onfido.client_verification.success'          => undef,
                },
                'Expected dd metrics';
        }
        'the event made it alive!';

        ok !$emissions->{underage_account_closed}, 'underage_account_closed event was not emitted';

        ok !$vrtc_client->status->disabled,        'Not disabled';
        ok !$test_client->status->disabled,        'Not disabled';
        ok $test_client->status->age_verification, 'Age verified';

        my $msg = mailbox_search(subject => qr/Underage client detection/);

        ok !$msg, 'underage email not sent to cs';

        subtest 'it has balance' => sub {
            $trading_platform_loginids = {};
            $emissions                 = {};
            $underage_result           = 'rejected';
            $reported_dob              = undef;
            $report_result             = 'rejected';

            $vrtc_client->status->clear_disabled();
            $vrtc_client->status->_build_all();
            $test_client->status->clear_disabled();
            $test_client->status->clear_age_verification();
            $test_client->status->clear_poi_name_mismatch();
            $test_client->status->_build_all();
            mailbox_clear();

            my $test_client_loginid   = $test_client->loginid;
            my $test_sibling_loginids = $test_sibling->loginid;

            $test_sibling->status->clear_disabled;
            $test_client->payment_free_gift(
                currency => 'USD',
                amount   => 10,
                remark   => 'freeeeee'
            );
            $test_sibling->payment_free_gift(
                currency => 'LTC',
                amount   => 5,
                remark   => 'freeeeee'
            );

            lives_ok {
                @metrics = ();
                BOM::Event::Actions::Client::client_verification({
                        check_url => $check->{href},
                    })->get;

                cmp_deeply + {@metrics},
                    +{
                    'event.onfido.client_verification.dispatch'          => undef,
                    'event.onfido.client_verification.not_verified'      => {tags => ['check:clear', 'country:COL', 'report:rejected']},
                    'event.onfido.client_verification.underage_detected' => {tags => ['check:clear', 'country:COL', 'report:rejected']},
                    'event.onfido.client_verification.success'           => undef,
                    },
                    'Expected dd metrics';
            }
            'the event made it alive!';

            ok !$emissions->{underage_account_closed}, 'underage_account_closed event not emitted';

            ok !$vrtc_client->status->disabled, 'Disabled status not set (dxtrader real)';

            ok !$test_client->status->disabled, 'Disabled status not set (dxtrader real)';

            ok !$test_client->status->age_verification, 'Not age verified';

            my $msg = mailbox_search(subject => qr/Underage client detection/);
            ok $msg, 'underage email sent to CS';
            ok $msg->{body} =~ /The following loginids have balance:/,  'Balances > 0 detected';
            ok $msg->{body} =~ qr/$test_client_loginid.*10\.00 USD/,    'Client with balance reported';
            ok $msg->{body} =~ qr/$test_sibling_loginids.*5\.0* LTC\b/, 'Sibling with balance reported';
            cmp_deeply $msg->{to}, [$brand->emails('authentications')], 'Expected to email address';
        };
    };

    $mocked_report->unmock_all();
    $mocked_onfido->unmock_all();
    $mocked_emitter->unmock_all();
};

subtest 'crypto_withdrawal_rejected_email' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client->email('nobody@deriv.com');
    $client->first_name('Alice');
    $client->last_name('Bob');
    $client->salutation('MR');
    $client->save;

    my $user = BOM::User->create(
        email          => $client->email,
        password       => "1234",
        email_verified => 1,
    )->add_client($client);

    undef @track_args;

    BOM::Event::Actions::Client::crypto_withdrawal_rejected_email({
            client_loginid         => $client->loginid,
            reject_reason          => 'highest_deposit_method_is_not_crypto',
            amount                 => '0.09',
            currency_code          => 'BTC',
            live_chat_url          => 'https://deriv.com/en/?is_livechat_open=true',
            cashier_transfer_url   => 'https://app.deriv.com/cashier/account-transfer?lang=en',
            cashier_p2p_url        => 'https://app.deriv.com/cashier/p2p?lang=en',
            cashier_withdrawal_url => 'https://app.deriv.com/cashier/withdrawal?lang=en',
            meta_data              => 'Perfect Money',
            fiat_account           => 'USD'
        })->get;

    my ($customer, %args) = @track_args;
    ok 1, 'is ok';

    is $args{event}, 'crypto_withdrawal_rejected_email', "got correct event name";

    cmp_deeply(
        $args{properties},
        {
            "lang"                   => "EN",
            "brand"                  => "deriv",
            "title"                  => "We were unable to process your withdrawal",
            "amount"                 => 0.09,
            "loginid"                => $client->loginid,
            "meta_data"              => "Perfect Money",
            "currency_code"          => "BTC",
            "live_chat_url"          => 'https://deriv.com/en/?is_livechat_open=true',
            "cashier_transfer_url"   => 'https://app.deriv.com/cashier/account-transfer?lang=en',
            "cashier_p2p_url"        => 'https://app.deriv.com/cashier/p2p?lang=en',
            "cashier_withdrawal_url" => 'https://app.deriv.com/cashier/withdrawal?lang=en',
            "reject_reason"          => "highest_deposit_method_is_not_crypto",
            "fiat_account"           => "USD"
        },
        'event properties are ok'
    );

    is $args{properties}->{loginid}, $client->loginid, "got correct customer loginid";
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
};

subtest 'account_verification_for_pending_payout event' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    undef @track_args;

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test@deriv.com',
    });

    my $args = {
        loginid    => $client->loginid,
        properties => {
            email => $client->email,
            date  => "28 Mar 2022"
        }};

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{account_verification_for_pending_payout};
    my $result  = $handler->($args)->get;
    ok $result, 'Success result';
    is scalar @track_args, 7, 'Track event is triggered';
    my ($customer, %returned_args) = @track_args;
    is $returned_args{event}, 'account_verification_for_pending_payout', 'track event name is set correctly';
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
};

subtest 'authenticated_with_scans event' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client->email('test2@deriv.com');
    $client->first_name('Jane');
    $client->last_name('Doe');
    $client->salutation('MR');
    $client->save;

    my $user = BOM::User->create(
        email          => $client->email,
        password       => "1234",
        email_verified => 1,
    )->add_client($client);

    undef @track_args;

    BOM::Event::Actions::Client::authenticated_with_scans({
            loginid => $client->loginid,
        })->get;

    my ($customer, %args) = @track_args;

    is $args{event}, 'authenticated_with_scans', "got correct event name";

    cmp_deeply $args{properties},
        {
        'email'         => $client->email,
        'first_name'    => $client->first_name,
        'live_chat_url' => 'https://deriv.com/en/?is_livechat_open=true',
        'lang'          => 'EN',
        'brand'         => 'deriv',
        'contact_url'   => 'https://deriv.com/en/contact-us',
        'loginid'       => $client->loginid
        },
        'event properties are ok';

    is $args{properties}->{loginid}, $client->loginid, "got correct customer loginid";
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
};

subtest 'request payment withdraw' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            first_name       => 'Backend',
            verification_url => 'https://Binary.url',
            email            => 'Backend@binary.com',
            code             => 'CODE',
            language         => 'EN',
        }};

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{request_payment_withdraw};
    my $result  = $handler->($args)->get;
    ok $result, 'Success result';
    is scalar @track_args, 7, 'Track event is triggered';
    my ($customer, %args) = @track_args;
    is $args{properties}->{loginid}, $test_client->loginid, "Got correct customer loginid";
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
};

subtest 'verify email closed account other' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            first_name       => 'Backend',
            verification_url => 'https://Binary.url',
            email            => 'Backend@binary.com',
            code             => 'CODE',
            language         => 'EN',
        }};

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{verify_email_closed_account_other};

    my $result = $handler->($args)->get;
    ok $result, 'Success result';
    is scalar @track_args, 7, 'Track event is triggered';
    my ($customer, %args) = @track_args;
    is $args{properties}->{loginid}, $test_client->loginid, "Got correct customer loginid";
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
};

subtest 'verify email closed account reset password' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            first_name       => 'Backend',
            verification_url => 'https://Binary.url',
            email            => 'Backend@binary.com',
            code             => 'CODE',
            language         => 'EN',
        }};

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{verify_email_closed_account_reset_password};

    my $result = $handler->($args)->get;
    ok $result, 'Success result';
    is scalar @track_args, 7, 'Track event is triggered';
    my ($customer, %args) = @track_args;
    is $args{properties}->{loginid}, $test_client->loginid, "Got correct customer loginid";
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
};

subtest 'verify email closed account opening' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            first_name       => 'Backend',
            verification_url => 'https://Binary.url',
            email            => 'Backend@binary.com',
            code             => 'CODE',
            language         => 'EN',
        }};

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{verify_email_closed_account_account_opening};
    my $result  = $handler->($args)->get;
    ok $result, 'Success result';
    is scalar @track_args, 7, 'Track event is triggered';
};

subtest 'self tagging affiliates' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'ID',
        app_id     => $app_id,
    );
    my $args = {
        properties => {
            email         => 'Backend@binary.com',
            live_chat_url => 'https://www.binary.com/en/contact.html?is_livechat_open=true',

        }};

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{self_tagging_affiliates};
    my $result  = $handler->($args)->get;
    ok $result, 'Success result';
    is scalar @track_args, 7, 'Track event is triggered';
};

subtest 'bonus_reject|approve' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            full_name => $test_client->full_name,
            brand     => $req->brand_name,
            language  => 'EN',
        }};

    my $handler = BOM::Event::Process->new(category => 'track')->actions->{bonus_approve};
    my $result  = $handler->($args)->get;

    ok $result, 'Success result';
    my ($customer, %args) = @track_args;
    is_deeply $args->{properties},
        {
        full_name => $test_client->full_name,
        brand     => 'deriv',
        language  => 'EN',
        },
        'Bonus approved';
    is $args{properties}->{loginid}, $test_client->loginid, "Got correct customer loginid";
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';

    undef @identify_args;
    undef @track_args;

    $handler = BOM::Event::Process->new(category => 'track')->actions->{bonus_reject};
    $result  = $handler->($args)->get;

    ok $result, 'Success result';
    ($customer, %args) = @track_args;
    is_deeply $args->{properties},
        {
        full_name => $test_client->full_name,
        brand     => 'deriv',
        language  => 'EN',
        },
        'Bonus rejected';
    is $args{properties}->{loginid}, $test_client->loginid, "Got correct customer loginid";
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
};

subtest 'request edd document upload' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            first_name    => $test_client->first_name,
            email         => $test_client->email,
            login_url     => 'https://oauth.deriv.com/oauth2/authorize?app_id=16929',
            expiry_date   => '',
            live_chat_url => 'https://deriv.com/en/?is_livechat_open=true',
        }};

    my $handler = BOM::Event::Process->new(category => 'track')->actions->{request_edd_document_upload};
    my $result  = $handler->($args)->get;
    ok $handler->($args);
    my ($customer, %args) = @track_args;
    is $args{event}, 'request_edd_document_upload', "event name";
    ok $result, 'Success result';
    is scalar @track_args, 7, 'Track event is triggered';
};

done_testing();
