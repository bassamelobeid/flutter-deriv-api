use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Test::Email;
use BOM::Database::UserDB;
use BOM::User;
use BOM::Test::Script::OnfidoMock;

use WebService::Async::Onfido;
use BOM::Event::Actions::Client;
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

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

    my $mocked_action    = Test::MockModule->new('BOM::Event::Actions::Client');
    my $document_content = 'it is a proffaddress document';
    $mocked_action->mock('_get_document_s3', sub { return Future->done($document_content) });
    $loop = IO::Async::Loop->new;

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
    my $redis = $services->redis_events_write();
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
    "ready_for_authentication no exception";
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
        gender     => $test_client2->gender,
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

    is_deeply([keys %$existing_onfido_docs], [$doc->id], 'now the doc is stored in db');

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

done_testing();

