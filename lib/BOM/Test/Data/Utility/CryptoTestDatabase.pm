package BOM::Test::Data::Utility::CryptoTestDatabase;

use BOM::Test;
use MooseX::Singleton;

sub _db_name {
    return 'crypto';
}

sub _db_migrations_dir {
    return '/home/git/regentmarkets/bom-postgres-cryptodb/config/sql/';
}

sub _db_unit_tests { }

sub _build__connection_parameters {
    my $self = shift;
    return {
        database       => $self->_db_name,
        domain         => 'TEST',
        driver         => 'Pg',
        host           => 'localhost',
        port           => $ENV{DB_TEST_PORT} // '5438',
        user           => 'postgres',
        password       => 'mRX1E3Mi00oS8LG',
        pgbouncer_port => '6432',
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
