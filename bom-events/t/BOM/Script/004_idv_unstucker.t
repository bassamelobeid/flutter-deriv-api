use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::Deep;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Customer;
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

my ($doc1, $cli1);
my ($doc2, $cli2);
my ($doc3, $cli3);
my ($doc4, $cli4);
my ($doc5, $cli5);

subtest 'add some documents outside the window' => sub {
    ($doc1, $cli1) = idv_document({
        email           => 'newdoc1@test.com',
        issuing_country => 'br',
        number          => '111.111.111-1',
        type            => 'cpf',
    });

    ($doc2, $cli2) = idv_document({
        email           => 'newdoc2@test.com',
        issuing_country => 'br',
        number          => '111.111.111-2',
        type            => 'cpf',
    });

    ($doc3, $cli3) = idv_document({
        email           => 'newdoc3@test.com',
        issuing_country => 'br',
        number          => '111.111.111-3',
        type            => 'cpf',
    });

    ($doc4, $cli4) = idv_document({
        email           => 'newdoc4@test.com',
        issuing_country => 'ar',
        number          => '23456789',
        type            => 'dni',
    });

    ($doc5, $cli5) = idv_document({
        email           => 'newdoc5@test.com',
        issuing_country => 'ar',
        number          => '12345678',
        type            => 'dni',
    });

    # these two are webhook based
    set_status('deferred', $doc4->{id});
    set_status('deferred', $doc5->{id});

    @emissions = ();
    @delays    = ();
    @dog_bag   = ();
    $log->clear;

    my $idv_model1 = BOM::User::IdentityVerification->new(user_id => $cli1->binary_user_id);
    my $idv_model2 = BOM::User::IdentityVerification->new(user_id => $cli2->binary_user_id);
    my $idv_model3 = BOM::User::IdentityVerification->new(user_id => $cli3->binary_user_id);
    my $idv_model4 = BOM::User::IdentityVerification->new(user_id => $cli4->binary_user_id);
    my $idv_model5 = BOM::User::IdentityVerification->new(user_id => $cli5->binary_user_id);

    ok $idv_model1->get_standby_document, 'There is a standby document for client 1';
    ok $idv_model2->get_standby_document, 'There is a standby document for client 2';
    ok $idv_model3->get_standby_document, 'There is a standby document for client 3';
    ok $idv_model4->get_standby_document, 'There is a standby document for client 4';
    ok $idv_model5->get_standby_document, 'There is a standby document for client 5';

    BOM::Event::Script::IDVUnstucker::run->get;

    ok $idv_model1->get_standby_document, 'There is still a standby document for client 1';
    ok $idv_model2->get_standby_document, 'There is still a standby document for client 2';
    ok $idv_model3->get_standby_document, 'There is still a standby document for client 3';
    ok $idv_model4->get_standby_document, 'There is still a standby document for client 4';
    ok $idv_model5->get_standby_document, 'There is still a standby document for client 5';

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

    my $idv_model1 = BOM::User::IdentityVerification->new(user_id => $cli1->binary_user_id);
    my $idv_model2 = BOM::User::IdentityVerification->new(user_id => $cli2->binary_user_id);
    my $idv_model3 = BOM::User::IdentityVerification->new(user_id => $cli3->binary_user_id);
    my $idv_model4 = BOM::User::IdentityVerification->new(user_id => $cli4->binary_user_id);
    my $idv_model5 = BOM::User::IdentityVerification->new(user_id => $cli5->binary_user_id);

    ok $idv_model1->get_standby_document, 'There is a standby document for client 1';
    ok $idv_model2->get_standby_document, 'There is a standby document for client 2';
    ok $idv_model3->get_standby_document, 'There is a standby document for client 3';
    ok $idv_model4->get_standby_document, 'There is a standby document for client 4';
    ok $idv_model5->get_standby_document, 'There is a standby document for client 5';

    BOM::Event::Script::IDVUnstucker::run->get;

    ok $idv_model1->get_standby_document,  'There is still a standby document for client 1';
    ok $idv_model2->get_standby_document,  'There is still a standby document for client 2';
    ok !$idv_model3->get_standby_document, 'There is no longer a standby document for client 3';
    ok $idv_model4->get_standby_document,  'There is still a standby document for client 4';
    ok $idv_model5->get_standby_document,  'There is still a standby document for client 5';

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

    my $idv_model1 = BOM::User::IdentityVerification->new(user_id => $cli1->binary_user_id);
    my $idv_model2 = BOM::User::IdentityVerification->new(user_id => $cli2->binary_user_id);
    my $idv_model3 = BOM::User::IdentityVerification->new(user_id => $cli3->binary_user_id);
    my $idv_model4 = BOM::User::IdentityVerification->new(user_id => $cli4->binary_user_id);
    my $idv_model5 = BOM::User::IdentityVerification->new(user_id => $cli5->binary_user_id);

    ok $idv_model1->get_standby_document,  'There is a standby document for client 1';
    ok $idv_model2->get_standby_document,  'There is a standby document for client 2';
    ok !$idv_model3->get_standby_document, 'There is no longer a standby document for client 3';
    ok $idv_model4->get_standby_document,  'There is a standby document for client 4';
    ok $idv_model5->get_standby_document,  'There is a standby document for client 5';

    BOM::Event::Script::IDVUnstucker::run->get;

    ok $idv_model1->get_standby_document,  'There is still a standby document for client 1';
    ok $idv_model2->get_standby_document,  'There is still a standby document for client 2';
    ok !$idv_model3->get_standby_document, 'There is no longer a standby document for client 3';
    ok $idv_model4->get_standby_document,  'There is still a standby document for client 4';
    ok $idv_model5->get_standby_document,  'There is still a standby document for client 5';

    cmp_deeply [@delays], [], 'No delays';

    cmp_deeply [@dog_bag], [], 'No datadog calls';

    cmp_deeply [@emissions], [], 'No emissions';

    cmp_deeply $log->msgs, [], 'No logs';
};

subtest 'deferred documents are also taken care for' => sub {
    updated_at('1 day',            $doc4->{id});
    updated_at('15 days 1 second', $doc5->{id});

    @emissions = ();
    @delays    = ();
    @dog_bag   = ();
    $log->clear;

    my $idv_model1 = BOM::User::IdentityVerification->new(user_id => $cli1->binary_user_id);
    my $idv_model2 = BOM::User::IdentityVerification->new(user_id => $cli2->binary_user_id);
    my $idv_model3 = BOM::User::IdentityVerification->new(user_id => $cli3->binary_user_id);
    my $idv_model4 = BOM::User::IdentityVerification->new(user_id => $cli4->binary_user_id);
    my $idv_model5 = BOM::User::IdentityVerification->new(user_id => $cli5->binary_user_id);

    ok $idv_model1->get_standby_document,  'There is a standby document for client 1';
    ok $idv_model2->get_standby_document,  'There is a standby document for client 2';
    ok !$idv_model3->get_standby_document, 'There is no longer a standby document for client 3';
    ok $idv_model4->get_standby_document,  'There is a standby document for client 4';
    ok $idv_model5->get_standby_document,  'There is a standby document for client 5';

    BOM::Event::Script::IDVUnstucker::run->get;

    ok $idv_model1->get_standby_document,  'There is still a standby document for client 1';
    ok $idv_model2->get_standby_document,  'There is still a standby document for client 2';
    ok !$idv_model3->get_standby_document, 'There is no longer a standby document for client 3';
    ok $idv_model4->get_standby_document,  'There is still a standby document for client 4';
    ok !$idv_model5->get_standby_document, 'There is no longer a standby document for client 5';

    cmp_deeply [@delays],
        [{
            after => 30,
        }
        ],
        'Expected delays';

    cmp_deeply [@dog_bag], ['idv.unstucker.requested'], 'Expected datadog calls';

    cmp_deeply [@emissions],
        ['idv_verification', BOM::Event::Actions::Client::IdentityVerification::idv_message_payload($cli4, $idv_model4->get_standby_document)],
        'Expected emissions';

    cmp_deeply $log->msgs, [], 'No logs';

    cmp_deeply decode_json_utf8($idv_model4->get_last_updated_document->{status_messages}), ['VERIFICATION_STARTED', 'Unstuck mechanism triggered'],
        'Expected messages';
};

sub updated_at {
    my ($interval, $id) = @_;

    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('UPDATE idv.document SET updated_at = NOW() - INTERVAL ? WHERE id = ?', undef, $interval, $id);
        });
}

sub set_status {
    my ($status, $id) = @_;

    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('UPDATE idv.document SET status = ? WHERE id = ?', undef, $status, $id);
        });
}

sub idv_document {
    my $args = shift;

    my $test_customer = BOM::Test::Customer->create(
        email_verified => 1,
        residence      => 'co',
        place_of_birth => 'co',
        citizen        => 'co',
        clients        => [{
                name        => 'CR',
                broker_code => 'CR',
            },
        ]);

    my $client = $test_customer->get_client_object('CR');

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $test_customer->get_user_id());

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

    return ($document, $client);
}

done_testing();
