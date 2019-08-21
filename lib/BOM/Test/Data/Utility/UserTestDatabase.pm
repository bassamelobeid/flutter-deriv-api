package BOM::Test::Data::Utility::UserTestDatabase;

use MooseX::Singleton;

use List::MoreUtils qw(uniq);
use BOM::Database::UserDB;
use BOM::Test;

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub _db_name {
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    return 'users' . $db_postfix;
}

sub _db_migrations_dir {
    return '/home/git/regentmarkets/bom-postgres-userdb/config/sql/';
}

sub _build__connection_parameters {
    my $self = shift;
    return {
        database       => $self->_db_name,
        domain         => 'TEST',
        driver         => 'Pg',
        host           => 'localhost',
        port           => '5436',
        user           => 'postgres',
        password       => 'mRX1E3Mi00oS8LG',
        pgbouncer_port => '6432',
    };
}

sub _post_import_operations {
    my $self = shift;
    return;
}

# TODO: not sure if this is the best way to do it...?
sub setup_db_underlying_group_mapping {
    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    my @uls  = Finance::Underlying::all_underlyings();
    my @underlying_groups = uniq map { $_->{market} } @uls;
    my @data = map { [$_->{symbol}, $_->{market}] } @uls;
    $dbic->run(
        ping => sub {
            my $sth = $_->prepare("INSERT INTO limits.underlying_group VALUES (?)");
            $sth->execute(($_)) foreach @underlying_groups;

            $sth = $_->prepare("INSERT INTO limits.underlying_group_mapping VALUES(?,?)");
            $sth->execute(@$_) foreach @data;
        });
    return;

}

with 'BOM::Test::Data::Utility::TestDatabaseSetup';

no Moose;
__PACKAGE__->meta->make_immutable;

## no critic (Variables::RequireLocalizedPunctuationVars)
sub import {
    my (undef, $init) = @_;

    if ($init && $init eq ':init') {
        __PACKAGE__->instance->prepare_unit_test_database;
        setup_db_underlying_group_mapping();
    }
    return;
}

1;
