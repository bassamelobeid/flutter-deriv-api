use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::Deep;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Event::Script::IDVUnstucker;
use BOM::Database::UserDB;
use BOM::User;
use BOM::User::IdentityVerification;
use BOM::Event::Actions::Client::IdentityVerification;
use JSON::MaybeUTF8 qw(:v2);

my $loop_mock = Test::MockModule->new('IO::Async::Loop');
my @delays;
$loop_mock->mock(
    'delay_future',
    sub {
        my (undef, %args) = @_;

        push @delays, +{%args};

        return Future->done;
    });

my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
my @dog_bag;
$dog_mock->mock(
    'stats_inc',
    sub {
        push @dog_bag, @_;
    });

my $emit_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
my @emissions;
$emit_mock->mock(
    'emit',
    sub {
        push @emissions, @_;
    });

my $mock_config_service = Test::MockModule->new('BOM::Config::Services');
$mock_config_service->mock(
    'is_enabled' => sub {
        if ($_[1] eq 'identity_verification') {
            return 1;
        }

        return 1;
    });

subtest 'empty IDV documents' => sub {
    @emissions = ();
    @delays    = ();
    @dog_bag   = ();
    $log->clear;

    BOM::Event::Script::IDVUnstucker::run->get;

    cmp_deeply [@delays], [], 'No delays';

    cmp_deeply [@dog_bag], [], 'No datadog calls';

    cmp_deeply [@emissions], [], 'No emissions';

    cmp_deeply $log->msgs, [], 'No logs';
};

my ($doc1, $cli1, $u1);
my ($doc2, $cli2, $u2);
my ($doc3, $cli3, $u3);

subtest 'add some documents outside the window' => sub {
    ($doc1, $cli1, $u1) = idv_document({
        email           => 'newdoc1@test.com',
        issuing_country => 'br',
        number          => '111.111.111-1',
        type            => 'cpf',
    });

    ($doc2, $cli2, $u2) = idv_document({
        email           => 'newdoc2@test.com',
        issuing_country => 'br',
        number          => '111.111.111-2',
        type            => 'cpf',
    });

    ($doc3, $cli3, $u3) = idv_document({
        email           => 'newdoc3@test.com',
        issuing_country => 'br',
        number          => '111.111.111-3',
        type            => 'cpf',
    });

    @emissions = ();
    @delays    = ();
    @dog_bag   = ();
    $log->clear;

    my $idv_model1 = BOM::User::IdentityVerification->new(user_id => $cli1->user->id);
    my $idv_model2 = BOM::User::IdentityVerification->new(user_id => $cli2->user->id);
    my $idv_model3 = BOM::User::IdentityVerification->new(user_id => $cli3->user->id);

    ok $idv_model1->get_standby_document, 'There is a standby document for client 1';
    ok $idv_model2->get_standby_document, 'There is a standby document for client 2';
    ok $idv_model3->get_standby_document, 'There is a standby document for client 3';

    BOM::Event::Script::IDVUnstucker::run->get;

    ok $idv_model1->get_standby_document, 'There is still a standby document for client 1';
    ok $idv_model2->get_standby_document, 'There is still a standby document for client 2';
    ok $idv_model3->get_standby_document, 'There is still a standby document for client 3';

    cmp_deeply [@delays], [], 'No delays';

    cmp_deeply [@dog_bag], [], 'No datadog calls';

    cmp_deeply [@emissions], [], 'No emissions';

    cmp_deeply $log->msgs, [], 'No logs';
};

subtest 'u1 to unstuck, u3 too old' => sub {
    updated_at('1 day',            $doc1->{id});
    updated_at('15 days 1 second', $doc3->{id});

    @emissions = ();
    @delays    = ();
    @dog_bag   = ();
    $log->clear;

    my $idv_model1 = BOM::User::IdentityVerification->new(user_id => $cli1->user->id);
    my $idv_model2 = BOM::User::IdentityVerification->new(user_id => $cli2->user->id);
    my $idv_model3 = BOM::User::IdentityVerification->new(user_id => $cli3->user->id);

    ok $idv_model1->get_standby_document, 'There is a standby document for client 1';
    ok $idv_model2->get_standby_document, 'There is a standby document for client 2';
    ok $idv_model3->get_standby_document, 'There is a standby document for client 3';

    BOM::Event::Script::IDVUnstucker::run->get;

    ok $idv_model1->get_standby_document,  'There is still a standby document for client 1';
    ok $idv_model2->get_standby_document,  'There is still a standby document for client 2';
    ok !$idv_model3->get_standby_document, 'There is no longer a standby document for client 3';

    cmp_deeply [@delays],
        [{
            after => 30,
        }
        ],
        'Expected delays';

    cmp_deeply [@dog_bag], ['idv.unstucker.requested'], 'Expected datadog calls';

    cmp_deeply [@emissions],
        ['idv_verification', BOM::Event::Actions::Client::IdentityVerification::idv_message_payload($cli1, $idv_model1->get_standby_document)],
        'Expected emissions';

    cmp_deeply $log->msgs, [], 'No logs';

    cmp_deeply decode_json_utf8($idv_model1->get_last_updated_document->{status_messages}), ['VERIFICATION_STARTED', 'Unstuck mechanism triggered'],
        'Expected messages';
};

subtest 'u1 should not retrigger this soon' => sub {
    @emissions = ();
    @delays    = ();
    @dog_bag   = ();
    $log->clear;

    my $idv_model1 = BOM::User::IdentityVerification->new(user_id => $cli1->user->id);
    my $idv_model2 = BOM::User::IdentityVerification->new(user_id => $cli2->user->id);
    my $idv_model3 = BOM::User::IdentityVerification->new(user_id => $cli3->user->id);

    ok $idv_model1->get_standby_document,  'There is a standby document for client 1';
    ok $idv_model2->get_standby_document,  'There is a standby document for client 2';
    ok !$idv_model3->get_standby_document, 'There is no longer a standby document for client 3';

    BOM::Event::Script::IDVUnstucker::run->get;

    ok $idv_model1->get_standby_document,  'There is still a standby document for client 1';
    ok $idv_model2->get_standby_document,  'There is still a standby document for client 2';
    ok !$idv_model3->get_standby_document, 'There is no longer a standby document for client 3';

    cmp_deeply [@delays], [], 'No delays';

    cmp_deeply [@dog_bag], [], 'No datadog calls';

    cmp_deeply [@emissions], [], 'No emissions';

    cmp_deeply $log->msgs, [], 'No logs';
};

sub updated_at {
    my ($interval, $id) = @_;

    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('UPDATE idv.document SET updated_at = NOW() - INTERVAL ? WHERE id = ?', undef, $interval, $id);
        });
}

sub idv_document {
    my $args = shift;

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $args->{email},
        residence      => 'co',
        place_of_birth => 'co',
        citizen        => 'co',
    });

    my $user = BOM::User->create(
        email          => $client->email,
        password       => "hello",
        email_verified => 1,
    );

    $user->add_client($client);
    $client->user($user);
    $client->binary_user_id($user->id);
    $client->save;

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);

    my $idv_document = {
        issuing_country => $args->{issuing_country},
        number          => $args->{number},
        type            => $args->{type},
    };

    my $document = $idv_model->add_document($idv_document);

    $idv_model->update_document_check({
        document_id  => $document->{id},
        status       => 'pending',
        messages     => [qw/VERIFICATION_STARTED/],
        provider     => 'zaig',
        request_body => '{}',
    });

    return ($document, $client, $user);
}

done_testing();
