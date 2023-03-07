use strict;
use warnings;

use Test::MockModule;
use Test::More;
use Test::Deep;
use Test::Exception;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Script::OnfidoMock;
use BOM::Event::Actions::Client;
use BOM::User::Onfido;
use BOM::Event::Script::OnfidoRetry;
use BOM::Database::UserDB;
use WebService::Async::Onfido::Check;

my $onfido = BOM::Event::Actions::Client::_onfido();

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => 'test1@bin.com',
    residence      => 'co',
    place_of_birth => 'co',
    citizen        => 'co',
});

my $user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);

$user->add_client($test_client);
$test_client->binary_user_id($user->id);
$test_client->save;

my $applicant = $onfido->applicant_create(
    first_name => 'Mary',
    last_name  => 'Jane',
    dob        => '1999-02-02',
)->get;
lives_ok { BOM::User::Onfido::store_onfido_applicant($applicant, $test_client->binary_user_id); } 'storing onfido applicant should pass';

my $doc1 = $onfido->document_upload(
    applicant_id    => $applicant->id,
    filename        => "document1.png",
    type            => 'passport',
    issuing_country => 'China',
    data            => 'This is passport',
    side            => 'front',
)->get;

my $doc2 = $onfido->document_upload(
    applicant_id    => $applicant->id,
    filename        => "document2.png",
    type            => 'driving_licence',
    issuing_country => 'China',
    data            => 'This is driving_licence',
    side            => 'front',
)->get;

lives_ok { BOM::User::Onfido::store_onfido_document($doc1, $applicant->id, $test_client->place_of_birth, $doc1->type, $doc1->side); }
'Storing onfido document 1 should pass';
lives_ok { BOM::User::Onfido::store_onfido_document($doc2, $applicant->id, $test_client->place_of_birth, $doc2->type, $doc2->side); }
'Storing onfido document 2 should pass';

my $onfido_mock  = Test::MockModule->new('BOM::User::Onfido');
my $event_mocker = Test::MockModule->new('BOM::Event::Actions::Client');
my $now          = Date::Utility->today;

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

my $check = $onfido->applicant_check(
    applicant_id => $applicant->id,
    # We don't want Onfido to start emailing people
    suppress_form_emails => 1,
    # Used for reporting and filtering in the web interface
    tags => ['tag1', 'tag2'],
    # On v3 we need to specify the array of documents
    document_ids => [$doc1->id, $doc2->id],
    # On v3 we need to specify the report names
    report_names               => [qw/document facial_similarity_photo/],
    suppress_from_email        => 0,
    charge_applicant_for_check => 0,
)->get;

subtest 'empty checks' => sub {
    @emissions = ();

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected';

    $check->{status} = 'in_progress';
    lives_ok { BOM::User::Onfido::store_onfido_check($applicant->id, $check); } 'Storing onfido check should pass';

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected (too soon)';

    $check->{status} = 'complete';
    lives_ok { BOM::User::Onfido::update_onfido_check($check); } 'Storing onfido check should pass';

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected (complete status)';

    # manipulate created_at
    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('UPDATE users.onfido_check SET created_at = NOW() - INTERVAL \'4 hours\'');
        });

    $check->{status} = 'complete';
    lives_ok { BOM::User::Onfido::update_onfido_check($check); } 'Storing onfido check should pass';

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected (complete status even if is not too soon)';
};

subtest 'in progress check are completed by Onfido' => sub {
    $check->{status} = 'in_progress';
    lives_ok { BOM::User::Onfido::update_onfido_check($check); } 'Storing onfido check should pass';
    @emissions = ();

    # manipulate created_at
    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('UPDATE users.onfido_check SET created_at = NOW() - INTERVAL \'4 hours\'');
        });
    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions],
        [{
            details => {check_url => re('\/v3\.4\/checks\/.+')},
            type    => 'client_verification'
        }
        ],
        'Expected emissions';
};

subtest 'in progress check are still in progress by Onfido' => sub {
    @emissions = ();

    # manipulate check status
    my $check_mock = Test::MockModule->new('WebService::Async::Onfido::Check');
    my $status;
    $check_mock->mock(
        'status',
        sub {
            return $status;
        });

    $status = 'in_progress';

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected (in_progress was returned by Onfido API)';

    $check_mock->unmock_all;
};

done_testing();
