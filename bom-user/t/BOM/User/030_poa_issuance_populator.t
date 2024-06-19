use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::User::Script::POAIssuancePopulator;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Database::UserDB;
use Date::Utility;

subtest 'Best Date' => sub {
    my $tests = [{
            hash1 => {

            },
            hash2 => {
                1 => Date::Utility->new('2020-10-10'),
                2 => Date::Utility->new('2020-10-10'),
                3 => Date::Utility->new('2020-10-10'),
            },
            expected => {
                1 => Date::Utility->new('2020-10-10'),
                2 => Date::Utility->new('2020-10-10'),
                3 => Date::Utility->new('2020-10-10'),
            }
        },
        {
            hash1 => {
                1 => Date::Utility->new('2020-10-10'),
                2 => Date::Utility->new('2020-10-10'),
                3 => Date::Utility->new('2020-10-10'),
            },
            hash2 => {

            },
            expected => {
                1 => Date::Utility->new('2020-10-10'),
                2 => Date::Utility->new('2020-10-10'),
                3 => Date::Utility->new('2020-10-10'),
            }
        },
        {
            hash1 => {
                1 => Date::Utility->new('2020-10-10'),
                2 => Date::Utility->new('2020-10-10'),
                3 => Date::Utility->new('2020-10-10'),
            },
            hash2 => {
                4 => Date::Utility->new('2020-10-10'),
                5 => Date::Utility->new('2020-10-10'),
                6 => Date::Utility->new('2020-10-10'),
            },
            expected => {
                1 => Date::Utility->new('2020-10-10'),
                2 => Date::Utility->new('2020-10-10'),
                3 => Date::Utility->new('2020-10-10'),
                4 => Date::Utility->new('2020-10-10'),
                5 => Date::Utility->new('2020-10-10'),
                6 => Date::Utility->new('2020-10-10'),
            }
        },
        {
            hash1 => {
                1  => Date::Utility->new('2020-10-11'),
                11 => Date::Utility->new('2020-10-10'),
                2  => Date::Utility->new('2020-10-10'),
                3  => Date::Utility->new('2020-10-10'),
                4  => Date::Utility->new('2020-10-10'),
            },
            hash2 => {
                1  => Date::Utility->new('2020-10-10'),
                22 => Date::Utility->new('2020-10-10'),
                2  => Date::Utility->new('2020-10-11'),
                3  => Date::Utility->new('2020-10-10'),
                5  => Date::Utility->new('2020-10-10'),
            },
            expected => {
                1  => Date::Utility->new('2020-10-11'),
                11 => Date::Utility->new('2020-10-10'),
                22 => Date::Utility->new('2020-10-10'),
                2  => Date::Utility->new('2020-10-11'),
                3  => Date::Utility->new('2020-10-10'),
                4  => Date::Utility->new('2020-10-10'),
                5  => Date::Utility->new('2020-10-10'),
            },
        },
        {
            hash1 => {
                1 => Date::Utility->new('2020-10-11'),
                2 => Date::Utility->new('2020-10-12'),
                3 => Date::Utility->new('2020-10-13'),
                4 => Date::Utility->new('2020-10-14'),
                5 => Date::Utility->new('2020-10-15'),
            },
            hash2 => {
                1 => Date::Utility->new('2020-10-15'),
                2 => Date::Utility->new('2020-10-14'),
                3 => Date::Utility->new('2020-10-13'),
                4 => Date::Utility->new('2020-10-12'),
                5 => Date::Utility->new('2020-10-11'),
            },
            expected => {
                1 => Date::Utility->new('2020-10-15'),
                2 => Date::Utility->new('2020-10-14'),
                3 => Date::Utility->new('2020-10-13'),
                4 => Date::Utility->new('2020-10-14'),
                5 => Date::Utility->new('2020-10-15'),
            },
        },
    ];

    for my $test ($tests->@*) {
        cmp_deeply BOM::User::Script::POAIssuancePopulator::get_best_date($test->{hash1}, $test->{hash2}), $test->{expected},
            'Expected hashref returned';
    }
};

subtest 'get massive arrayref' => sub {

    my $tests = [{
            hash => {
                1 => Date::Utility->new('2020-10-10'),
                2 => Date::Utility->new('2020-10-10'),
                3 => Date::Utility->new('2020-10-10'),
            },
            expected => [{
                    binary_user_id => 1,
                    issue_date     => '2020-10-10',
                },
                {
                    binary_user_id => 2,
                    issue_date     => '2020-10-10',
                },
                {
                    binary_user_id => 3,
                    issue_date     => '2020-10-10',
                },
            ]
        },
        {
            hash => {
                1 => Date::Utility->new('2020-10-13'),
                2 => Date::Utility->new('2020-10-12'),
                3 => Date::Utility->new('2020-10-11'),
            },
            expected => [{
                    binary_user_id => 1,
                    issue_date     => '2020-10-13',
                },
                {
                    binary_user_id => 2,
                    issue_date     => '2020-10-12',
                },
                {
                    binary_user_id => 3,
                    issue_date     => '2020-10-11',
                },
            ]
        },
        {
            hash     => {},
            expected => []
        },
    ];

    for my $test ($tests->@*) {
        cmp_bag BOM::User::Script::POAIssuancePopulator::get_massive_arrayref($test->{hash}), $test->{expected}, 'Expected arrayref returned';
    }
};

my ($cli1, $u1) = add_client({
    email       => 'test1@test.com',
    broker_code => 'CR',
});
my ($cli2, $u2) = add_client({
    email       => 'test2@test.com',
    broker_code => 'CR',
});
my ($cli3, $u3) = add_client({
    email       => 'test2@test.com',
    broker_code => 'MF',
    user        => $u2,
});
my ($cli4, $u4) = add_client({
    email       => 'test4@test.com',
    broker_code => 'CR',
});

my $now = Date::Utility->new();

subtest 'POA Issuance Populator' => sub {
    clear_poa_issuance();

    add_document(
        $cli1,
        {
            file_name                  => 'test1.png',
            document_type              => 'bank_statement',
            document_format            => 'png',
            document_path              => '/tmp/test1.png',
            authentication_method_code => 'ID_DOCUMENT',
            checksum                   => '999-1',
            status                     => 'verified',
            issue_date                 => $now->date_yyyymmdd,
            document_id                => 'doc1',
            status                     => 'verified',
        });

    add_document(
        $cli2,
        {
            file_name                  => 'test2.png',
            document_type              => 'bank_statement',
            document_format            => 'png',
            document_path              => '/tmp/test2.png',
            authentication_method_code => 'ID_DOCUMENT',
            checksum                   => '999-2',
            status                     => 'verified',
            issue_date                 => $now->date_yyyymmdd,
            document_id                => 'doc2',
            status                     => 'verified',
        });

    add_document(
        $cli3,
        {
            file_name                  => 'test3.png',
            document_type              => 'bank_statement',
            document_format            => 'png',
            document_path              => '/tmp/test3.png',
            authentication_method_code => 'ID_DOCUMENT',
            checksum                   => '999-3',
            status                     => 'verified',
            issue_date                 => $now->date_yyyymmdd,
            document_id                => 'doc3',
            status                     => 'verified',
        });

    add_document(
        $cli4,
        {
            file_name                  => 'test4.png',
            document_type              => 'bank_statement',
            document_format            => 'png',
            document_path              => '/tmp/test4.png',
            authentication_method_code => 'ID_DOCUMENT',
            checksum                   => '999-4',
            status                     => 'verified',
            issue_date                 => $now->date_yyyymmdd,
            document_id                => 'doc4',
            status                     => 'verified',
        });

    # running it with limit 1 ensures the inner loop is hit multiple times
    # this is not the global limit but the limit per broker code hit
    BOM::User::Script::POAIssuancePopulator::run({limit => 1});

    cmp_bag get_poa_issuance(), [$u1->id, $u2->id, $u4->id], 'Expected POA Issuance';

    # ensure the same result with default limit
    clear_poa_issuance();

    BOM::User::Script::POAIssuancePopulator::run();

    cmp_bag get_poa_issuance(), [$u1->id, $u2->id, $u4->id], 'Expected POA Issuance';

    # make cli3 lifetime valid
    clear_poa_issuance();

    add_document(
        $cli3,
        {
            file_name                  => 'test4.png',
            document_type              => 'bank_statement',
            document_format            => 'png',
            document_path              => '/tmp/test4.png',
            authentication_method_code => 'ID_DOCUMENT',
            checksum                   => '999-4',
            status                     => 'verified',
            issue_date                 => $now->date_yyyymmdd,
            document_id                => 'doc4',
            status                     => 'verified',
            lifetime_valid             => 1,
        });

    # running it with limit 1 ensures the inner loop is hit multiple times
    BOM::User::Script::POAIssuancePopulator::run({limit => 1});

    cmp_bag get_poa_issuance(), [$u1->id, $u4->id], 'Expected POA Issuance';

    # ensure the same result with default limit
    clear_poa_issuance();

    BOM::User::Script::POAIssuancePopulator::run();

    cmp_bag get_poa_issuance(), [$u1->id, $u4->id], 'Expected POA Issuance';
};

sub get_poa_issuance {
    my $user_db = BOM::Database::UserDB::rose_db()->dbic;

    return [
        map { $_->{binary_user_id} } $user_db->run(
            fixup => sub {
                # put a boundary in the future to ensure the records will get caught
                $_->selectall_arrayref(
                    'SELECT binary_user_id FROM users.poa_issuance WHERE issue_date < ? ORDER BY issue_date DESC LIMIT ?',
                    {Slice => {}},
                    $now->plus_time_interval('10y')->date_yyyymmdd, 1000
                );
            }
        )->@*
    ];
}

sub clear_poa_issuance {
    my $user_db = BOM::Database::UserDB::rose_db()->dbic;
    $user_db->run(
        fixup => sub {
            $_->do('DELETE FROM users.poa_issuance');
        });
}

sub add_document {
    my ($client, $doc) = @_;

    my $file = $client->start_document_upload($doc);

    return $client->finish_document_upload($file->{file_id}, $doc->{status});
}

sub add_client {
    my $args = shift;

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $args->{broker_code},
    });

    my $test_user = $args->{user} // BOM::User->create(
        email          => $args->{email},
        password       => "hello",
        email_verified => 1,
    );
    $test_user->add_client($test_client);
    $test_client->place_of_birth('cn');
    $test_client->binary_user_id($test_user->id);
    $test_client->save;

    return ($test_client, $test_user);
}

done_testing;
