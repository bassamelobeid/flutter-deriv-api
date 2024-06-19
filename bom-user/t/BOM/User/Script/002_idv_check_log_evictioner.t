use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockTime;

use BOM::Database::UserDB;
use Date::Utility;
use BOM::Config;
use BOM::User::Script::IDVCheckLogEvictioner;

subtest 'Evictioner' => sub {
    my $user_db = BOM::Database::UserDB::rose_db()->dbic;

    subtest 'create many partitions' => sub {
        my $partitions = [];
        my $base       = Date::Utility->new();

        for (1 .. 48) {
            $user_db->run(
                fixup => sub {
                    $_->do("SELECT idv.create_document_check_log_partition (?::TIMESTAMP)", undef, $base->date_yyyymmdd);
                });

            my @date = split(/-/, $base->date);
            push $partitions->@*, sprintf('document_check_log_%04d_%02d', $date[0], $date[1]);
            $base = $base->minus_months(1);
        }

        my @tables = $user_db->run(
            fixup => sub {
                $_->selectall_array(
                    "SELECT c.relname AS partition FROM pg_class AS c JOIN pg_namespace AS n ON n.oid=c.relnamespace WHERE c.relname LIKE ? AND n.nspname = ? AND c.relkind = ?",
                    undef, '%document_check_log_%', 'idv', 'r'
                );
            });

        cmp_bag $partitions, [map { shift @$_ } @tables], 'Expected partitions created';
        is scalar @tables, 48, '48 partitions';
    };

    subtest 'run the script' => sub {
        my $partitions = [];
        my $base       = Date::Utility->new()->plus_months(1);

        for my $n (1 .. 48) {
            $base = $base->minus_months(1);

            next if $n > 25 && $n <= 37;

            my @date = split(/-/, $base->date);
            push $partitions->@*, sprintf('document_check_log_%04d_%02d', $date[0], $date[1]);
        }
        BOM::User::Script::IDVCheckLogEvictioner::run();

        my @tables = $user_db->run(
            fixup => sub {
                $_->selectall_array(
                    "SELECT c.relname AS partition FROM pg_class AS c JOIN pg_namespace AS n ON n.oid=c.relnamespace WHERE c.relname LIKE ? AND n.nspname = ? AND c.relkind = ?",
                    undef, '%document_check_log_%', 'idv', 'r'
                );
            });

        cmp_bag $partitions, [map { shift @$_ } @tables], 'Expected partitions left after eviction';
        is scalar @tables, 36, '36 partitions';
    };

    subtest 'shift time' => sub {
        my $base = Date::Utility->new()->plus_months(1);
        Test::MockTime::set_absolute_time(Date::Utility->new()->plus_time_interval('2y')->date_yyyymmdd);

        my $partitions = [];

        for my $n (1 .. 48) {
            $base = $base->minus_months(1);

            next if $n > 25 && $n <= 37 || $n <= 13 && $n > 1;

            my @date = split(/-/, $base->date);
            push $partitions->@*, sprintf('document_check_log_%04d_%02d', $date[0], $date[1]);
        }

        BOM::User::Script::IDVCheckLogEvictioner::run();

        my @tables = $user_db->run(
            fixup => sub {
                $_->selectall_array(
                    "SELECT c.relname AS partition FROM pg_class AS c JOIN pg_namespace AS n ON n.oid=c.relnamespace WHERE c.relname LIKE ? AND n.nspname = ? AND c.relkind = ?",
                    undef, '%document_check_log_%', 'idv', 'r'
                );
            });

        cmp_bag $partitions, [map { shift @$_ } @tables], 'Expected partitions left after eviction';
        is scalar @tables, 24, '24 partitions';
    }
};

done_testing();
