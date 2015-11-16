package BOM::Test::Data::Utility::UnitTestChronicle;

=head1 NAME

BOM::Test::Data::Utility::UnitTestChronicle - Utils to set-up environment for testing Chronicle

=head1 SYNOPSIS

 use BOM::Test::Data::Utility::UnitTestChronicle qw(init_chronicle);

 init_chronicle;

=head1 DESCRIPTION

This module has a single function called 'init_chronicle' which when called empties chronicle storages (Redis and Pg) which
has to be called before running any unit test on chronicle.

=cut

use 5.010;
use strict;
use warnings FATAL => 'all';
use Carp;
use RedisDB 2.14;
use DBI;
use YAML::XS;

use base qw( Exporter );
our @EXPORT_OK = qw(init_chronicle);

sub _get_redis_connection {
    state $redis;

    $redis //= RedisDB->new(
        host               => "127.0.0.1",
        port               => 6380,
        reconnect_attempts => 3,
        on_connect_error   => sub {
            confess "Cannot connect to redis server for chronicle";
        });

    return $redis;
}

sub _get_db_handler {
    state $pg;

    $pg //= DBI->connect('dbi:Pg:dbname=chronicle;host=localhost;port=5437', 'postgres', 'picabo')
        or croak $DBI::errstr;

    return $pg;
}

sub init_chronicle {
    #flushall on redis-cli -p 6380
    my $redis = _get_redis_connection;
    $redis->auth('w09XKchis3YoP^fPJ2FQ2PjI@DfMgB5taPNIDFlQTfRQPr#L729aE33mMSIxO5n%');
    $redis->flushall;

    #delete from chronicle o pg chronicle
    my $pg = _get_db_handler;

    $pg->do('delete from chronicle;');
    $pg->disconnect();
}

=head2 create doc()

    Create a new document in the test database

    params:
    $yaml_db  => The name of the entity in the YAML file (eg. promo_code)
    $data_mod       => hasref of modifictions required to the data (optional)

=cut

sub create_doc {
    my ($yaml_db, $data_mod) = @_;

    my $save = 1;
    if (exists $data_mod->{save}) {
        $save = delete $data_mod->{save};
    }

    # get data to insert
    my $fixture = YAML::XS::LoadFile('/home/git/regentmarkets/bom-test/data/couch_unit_test.yml');
    my $data    = $fixture->{$yaml_db}{data};

    # modify data?
    for (keys %$data_mod) {
        $data->{$_} = $data_mod->{$_};
    }

    # use class to create the Couch doc
    my $class_name = $fixture->{$yaml_db}{class_name};
    my $obj        = $class_name->new($data);

    if ($save) {
        $obj->save;
    }

    return $obj;
}

1;
