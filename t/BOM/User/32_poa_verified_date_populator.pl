use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::User::Script::POAVerifiedDatePopulator;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Database::UserDB;
use Date::Utility;

subtest 'get massive arrayref' => sub {

    my $tests = [{
            hash => {
                1 => Date::Utility->new('2020-10-10'),
                2 => Date::Utility->new('2020-10-10'),
                3 => Date::Utility->new('2020-10-10'),
            },
            expected => [{
                    binary_user_id => 1,
                    verified_date  => '2020-10-10',
                },
                {
                    binary_user_id => 2,
                    verified_date  => '2020-10-10',
                },
                {
                    binary_user_id => 3,
                    verified_date  => '2020-10-10',
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
                    verified_date  => '2020-10-13',
                },
                {
                    binary_user_id => 2,
                    verified_date  => '2020-10-12',
                },
                {
                    binary_user_id => 3,
                    verified_date  => '2020-10-11',
                },
            ]
        },
        {
            hash     => {},
            expected => []
        },
    ];

    for my $test ($tests->@*) {
        cmp_bag BOM::User::Script::POAVerifiedDatePopulator::get_massive_arrayref($test->{hash}), $test->{expected}, 'Expected arrayref returned';
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

subtest 'POA Verified Date Populator' => sub {
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

    # POAVerifiedDatePopulator performs an update operation, so we need records to already be there
    BOM::User::Script::POAIssuancePopulator::run();

    # running it with limit 1 ensures the inner loop is hit multiple times
    # this is not the global limit but the limit per broker code hit
    BOM::User::Script::POAVerifiedDatePopulator::run({limit => 1});

    cmp_bag get_poa_verified_dates(), [$u1->id, $u2->id, $u4->id], 'Expected POA Issuance';

    # ensure the same result with default limit
    clear_poa_verified_date();

    BOM::User::Script::POAVerifiedDatePopulator::run();

    cmp_bag get_poa_verified_dates(), [$u1->id, $u2->id, $u4->id], 'Expected POA Issuance';

    # make cli3 lifetime valid
    clear_poa_verified_date();

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
    BOM::User::Script::POAVerifiedDatePopulator::run({limit => 1});

    cmp_bag get_poa_verified_dates(), [$u1->id, $u4->id], 'Expected POA Issuance';

    # ensure the same result with default limit
    clear_poa_verified_date();

    BOM::User::Script::POAVerifiedDatePopulator::run();

    cmp_bag get_poa_verified_dates(), [$u1->id, $u4->id], 'Expected POA Issuance';
};

sub get_poa_verified_dates {
    my $user_db = BOM::Database::UserDB::rose_db()->dbic;

    return [
        map { $_->{binary_user_id} } $user_db->run(
            fixup => sub {
                # put a boundary in the future to ensure the records will get caught
                $_->selectall_arrayref(
                    'SELECT * FROM users.get_outdated_poa(?, ?)',
                    {Slice => {}},
                    $now->plus_time_interval('10y')->date_yyyymmdd, 1000
                );
            }
        )->@*
    ];
}

sub clear_poa_verified_date {
    my $user_db = BOM::Database::UserDB::rose_db()->dbic;
    $user_db->run(
        fixup => sub {
            $_->do('UPDATE users.poa_issuance SET verified_date = NULL');
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
        email    => $args->{email},
        password => 'secret_pwd',
    );
    $test_user->add_client($test_client);
    $test_client->binary_user_id($test_user->id);
    $test_client->save;

    return ($test_client, $test_user);
}

done_testing;
