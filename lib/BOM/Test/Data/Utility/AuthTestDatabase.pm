package BOM::Test::Data::Utility::AuthTestDatabase;

use MooseX::Singleton;

use BOM::Test;

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub _db_name {
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    return 'auth' . $db_postfix;
}

sub _db_migrations_dir {
    return '/home/git/regentmarkets/bom-postgres-authdb/config/sql/';
}

sub _build__connection_parameters {
    my $self = shift;
    return {
        database       => $self->_db_name,
        domain         => 'TEST',
        driver         => 'Pg',
        host           => 'localhost',
        port           => '5435',
        user           => 'postgres',
        password       => 'mRX1E3Mi00oS8LG',
        pgbouncer_port => '6432',
        pg_version     => '9.5',
    };
}

sub _post_import_operations {
    my $self = shift;
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
    }
    return;
}

1;
