package BOM::Test::Data::Utility::UnitTestChronicle;

=head1 NAME


=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

use 5.010;
use strict;
use warnings FATAL => 'all';
use Carp;
use RedisDB 2.14;
use DBI;

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

1;
