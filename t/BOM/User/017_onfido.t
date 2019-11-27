use strict;
use warnings;
use Test::More tests => 7;
use Test::Exception;
use Test::NoWarnings;
use Test::Warn;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::OnfidoMock;

use BOM::User::Onfido;
use WebService::Async::Onfido;

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

my $loop = IO::Async::Loop->new;
$loop->add(
    my $onfido = WebService::Async::Onfido->new(
        token    => 'test_token',
        base_uri => $ENV{ONFIDO_URL}));

my $app1 = $onfido->applicant_create(
    title      => 'Mr',
    first_name => $test_client->first_name,
    last_name  => $test_client->last_name,
    email      => $test_client->email,
    gender     => $test_client->gender,
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

my $app2 = $onfido->applicant_create(
    title      => 'Mr',
    first_name => $test_client->first_name,
    last_name  => $test_client->last_name,
    email      => $test_client->email,
    gender     => $test_client->gender,
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

subtest 'store & get onfido applicant' => sub {
    throws_ok {
        warning_like { BOM::User::Onfido::store_onfido_applicant($app1, 123456); }
        qr/insert or update on table "onfido_applicant" violates foreign key constraint/s, "have warning";
    }
    qr/Fail to store Onfido/, 'incorrect user_id will cause exception';
    lives_ok { BOM::User::Onfido::store_onfido_applicant($app1, $test_client->binary_user_id); } 'now storing onfido should pass';
    lives_ok { BOM::User::Onfido::store_onfido_applicant($app2, $test_client->binary_user_id); } 'store app2 ';
    throws_ok {
        warning_like { BOM::User::Onfido::get_all_user_onfido_applicant("hello"); } qr/invalid input syntax for integer/, 'there is warn'
    }
    qr/Please check USER_ID/, 'incorrect user-id will cause exception';
    my $result = BOM::User::Onfido::get_all_user_onfido_applicant($test_client->binary_user_id);
    ok($result, 'now has result when getting applicant');
    is_deeply([sort keys %$result], [sort ($app1->id, $app2->id)], 'applicants correct');
};

subtest 'store & get onfido live photo' => sub {
    my @photos;
    for (1 .. 2) {
        my $photo = $onfido->live_photo_upload(
            applicant_id => $app1->id,
            filename     => 'photo1.jpg',
            data         => 'photo ' x 50
        )->get;
        lives_ok { BOM::User::Onfido::store_onfido_live_photo($photo, $app1->id); } 'Storing onfido live photo should pass';
        push @photos, $photo;
    }
    my $result;
    lives_ok { $result = BOM::User::Onfido::get_onfido_live_photo($test_client->binary_user_id, $app1->id); } 'Storing onfido live photo should pass';
    is_deeply([sort keys %$result], [sort map { $_->id } @photos], 'the result of get photo ok');
};

subtest 'store & get onfido document' => sub {
    my $doc1 = $onfido->document_upload(
        applicant_id    => $app1->id,
        filename        => "document1.png",
        type            => 'passport',
        issuing_country => 'China',
        data            => 'This is passport',
        side            => 'front',
    )->get;
    my $doc2 = $onfido->document_upload(
        applicant_id    => $app1->id,
        filename        => "document2.png",
        type            => 'driving_licence',
        issuing_country => 'China',
        data            => 'This is driving_licence',
        side            => 'front',
    )->get;
    lives_ok { BOM::User::Onfido::store_onfido_document($doc1, $app1->id, $test_client->place_of_birth, $doc1->type, $doc1->side); }
    'Storing onfido document should pass';
    lives_ok { BOM::User::Onfido::store_onfido_document($doc2, $app1->id, $test_client->place_of_birth, $doc2->type, $doc2->side); }
    'Storing onfido document should pass';
    my $result;
    lives_ok { $result = BOM::User::Onfido::get_onfido_document($test_client->binary_user_id, $app1->id); } 'Storing onfido live photo should pass';
    is_deeply([sort keys %$result], [sort $doc1->id, $doc2->id], 'the result of get photo ok');
};

my $check;
subtest 'store & update & fetch check ' => sub {
    $check = $onfido->applicant_check(
        applicant_id => $app1->id,
        type         => 'standard',
        reports      => [
            {name => 'document'},
            {
                name    => 'facial_similarity',
                variant => 'standard'
            }
        ],
        tags                       => ['tag1', 'tag2'],
        suppress_from_email        => 0,
        async                      => 1,
        charge_applicant_for_check => 0,
    )->get;
    $check->{status} = 'in_progress';
    lives_ok { BOM::User::Onfido::store_onfido_check($app1->id, $check); } 'Storing onfido check should pass';
    my $result;
    lives_ok { $result = BOM::User::Onfido::get_latest_onfido_check($test_client->binary_user_id); } 'get latest onfido check should pass';
    is($result->{id},     $check->id,    'get latest onfido check result ok');
    is($result->{status}, 'in_progress', 'the status of check is in_progress');
    $check->{status} = 'complete';
    lives_ok { BOM::User::Onfido::update_onfido_check($check) } 'update check ok';
    lives_ok { $result = BOM::User::Onfido::get_latest_onfido_check($test_client->binary_user_id); } 'get check again';
    is($result->{status}, 'complete', 'the status of check is complete');
};

subtest 'store & fetch report' => sub {
    my @all_report = $check->reports->as_list->get;
    for my $report (@all_report) {
        $report->{breakdown} = {};
        $report->{properties} = {};
        lives_ok { BOM::User::Onfido::store_onfido_report($check, $report) } 'store report ok';
    }
    my $result;

    lives_ok { $result = BOM::User::Onfido::get_all_onfido_reports($test_client->binary_user_id, $check->id) } "get report ok";
    is_deeply([sort keys %$result], [sort map {$_->id} @all_report], 'getting all reports ok');
};
