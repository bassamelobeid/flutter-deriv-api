use strict;
use warnings;

use Test::MockModule;
use Test::More;
use Test::Deep;
use Test::Exception;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Test::Script::OnfidoMock;
use BOM::Event::Actions::Client;
use BOM::User::Onfido;
use BOM::Event::Script::OnfidoRetry;
use BOM::Database::UserDB;
use WebService::Async::Onfido::Check;

my $onfido = BOM::Event::Actions::Client::_onfido();

my $service_contexts = BOM::Test::Customer::get_service_contexts();

my $test_customer = BOM::Test::Customer->create(
    residence      => 'co',
    place_of_birth => 'co',
    citizen        => 'co',
    clients        => [{
            name            => 'CR',
            broker_code     => 'CR',
            default_account => 'USD',
        },
    ]);

my $user_data = BOM::Service::user(
    context => $service_contexts->{user},
    command => 'get_all_attributes',
    user_id => $test_customer->get_user_id(),
);
die "User-service read failure for " . $test_customer->get_user_id() . ": $user_data->{message}" unless $user_data->{status} eq 'ok';
$user_data = $user_data->{attributes};

my $applicant = $onfido->applicant_create(
    first_name => 'Mary',
    last_name  => 'Jane',
    dob        => '1999-02-02',
)->get;

lives_ok { BOM::User::Onfido::store_onfido_applicant($applicant, $test_customer->get_user_id()); } 'storing onfido applicant should pass';

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

lives_ok { BOM::User::Onfido::store_onfido_document($doc1, $applicant->id, $user_data->{place_of_birth}, $doc1->type, $doc1->side); }
'Storing onfido document 1 should pass';
lives_ok { BOM::User::Onfido::store_onfido_document($doc2, $applicant->id, $user_data->{place_of_birth}, $doc2->type, $doc2->side); }
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

my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
my @doggy_bag;

$dog_mock->mock(
    'stats_inc',
    sub {
        push @doggy_bag, shift;
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
    @doggy_bag = ();

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected';
    cmp_deeply [@doggy_bag], [], 'Empty datadog as expected';

    $check->{status} = 'in_progress';
    lives_ok { BOM::User::Onfido::store_onfido_check($applicant->id, $check); } 'Storing onfido check should pass';

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected (too soon)';
    cmp_deeply [@doggy_bag], [], 'Empty datadog as expected';

    $check->{status} = 'complete';
    lives_ok { BOM::User::Onfido::update_onfido_check($check); } 'Storing onfido check should pass';

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected (complete status)';
    cmp_deeply [@doggy_bag], [], 'Empty datadog as expected';

    # manipulate created_at
    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('UPDATE users.onfido_check SET created_at = NOW() - INTERVAL \'4 hours\'');
        });

    $check->{status} = 'complete';
    lives_ok { BOM::User::Onfido::update_onfido_check($check); } 'Storing onfido check should pass';

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected (complete status even if is not too soon)';
    cmp_deeply [@doggy_bag], [], 'Empty datadog as expected';
};

subtest 'in progress check are completed by Onfido' => sub {
    $check->{status} = 'in_progress';
    lives_ok { BOM::User::Onfido::update_onfido_check($check); } 'Storing onfido check should pass';
    @emissions = ();
    @doggy_bag = ();

    # manipulate created_at
    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('UPDATE users.onfido_check SET created_at = NOW() - INTERVAL \'4 hours\'');
        });
    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@doggy_bag], ['onfido.api.hit', 'onfido.retry'], 'Expected retry to the dog';

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
    @doggy_bag = ();

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

    cmp_deeply [@emissions], [],                 'Empty emissions as expected (in_progress was returned by Onfido API)';
    cmp_deeply [@doggy_bag], ['onfido.api.hit'], 'One API hit';

    $check_mock->unmock_all;
};

subtest 'withdraw old onfido checks' => sub {
    # manipulate created_at
    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('UPDATE users.onfido_check SET status=\'in_progress\', created_at = NOW() - INTERVAL \'15 days 1 second\'');
        });
    @emissions = ();

    # manipulate check status
    my $check_mock = Test::MockModule->new('WebService::Async::Onfido::Check');
    my $status;
    $check_mock->mock(
        'status',
        sub {
            return $status;
        });

    $status = 'complete';

    BOM::Event::Script::OnfidoRetry::run()->get();

    cmp_deeply [@emissions], [], 'Empty emissions as expected (checks are too old now!)';

    my $checks = BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT id, status FROM users.onfido_check', {Slice => {}});
        });

    # all the checks should've been withdrawn
    ok List::Util::all { $_->{status} eq 'withdrawn' } $checks->@*;

    $check_mock->unmock_all;
};

done_testing();
