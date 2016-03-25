package BOM::Test::Data::Utility::UserTestDatabase;

use MooseX::Singleton;

sub _db_name {
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    return 'users' . $db_postfix;
}

sub _db_migrations_dir {
    return 'userdb';
}

sub _build__connection_parameters {
    my $self = shift;
    return {
        database => $self->_db_name,
          domain => 'TEST',
        driver   => 'Pg',
        host     => 'localhost',
        port     => '5436',
        user     => 'postgres',
        password => 'mRX1E3Mi00oS8LG',
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
    my ( $class, $init ) = @_;

    if ( $init && $init eq ':init' ) {
        __PACKAGE__->instance->prepare_unit_test_database;
    }
    return;
}

1;
