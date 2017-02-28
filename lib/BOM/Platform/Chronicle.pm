package BOM::Plarform::Chronicle;

=head1 NAME

BOM::Plarform::Chronicle - Provides efficient data storage for volatile and time-based data

=head1 DESCRIPTION

This module contains helper methods which can be used to store and retrieve information
on an efficient storage with below properties:

=over 4

=item B<Timeliness>

It is assumed that data to be stored are time-based meaning they change over time and the latest version is most important for us.
Many data structures in our system fall into this category (For example Volatility Surfaces, Interest Rate information, ...).

=item B<Efficient>

The module uses Redis cache to provide efficient data storage and retrieval.

=item B<Persistent>

In addition to caching every incoming data, it is also stored in PostgresSQL for future retrieval.

=item B<Distributed>

These data are stored in distributed storage so they will be replicated to other servers instantly.

=item B<Transparent>

This modules hides all the details about distribution, caching, database structure and ... from developer. He only needs to call a method
to save data and another method to retrieve it. All the underlying complexities are handled by the module.

=back

There are three important methods this module provides:

=over 4

=item C<set>

Given a category, name and value stores the JSONified value in Redis and PostgreSQL database under "category::name" group and also stores current
system time as the timestamp for the data (Which can be used for future retrieval if we want to get data as of a specific time). Note that the value
MUST be either hash-ref or array-ref.

=item C<get>

Given a category and name returns the latest version of the data according to current Redis cache

=item C<get_for>

Given a category, name and timestamp returns version of data under "category::name" as of the given date (using a DB lookup).

=back

=head1 Example

 my $d = get_some_data();

 #store data into Chronicle
 BOM::Plarform::Chronicle::set("vol_surface", "frxUSDJPY", $d);

 #retrieve latest data stored for "vol_surface" and "frxUSDJPY"
 my $dt = BOM::Plarform::Chronicle::set("vol_surface", "frxUSDJPY");

 #find vol_surface for frxUSDJPY as of a specific date
 my $some_old_data = get_for("vol_surface", "frxUSDJPY", $epoch1);

=head1 Future directions

As we continue migrating new data types to this model, there will probably be more changes to this module to make it fit for our requirements in Quant code-base.

=cut

use strict;
use warnings;

# we cache connection to Redis, so we use state feature.
use feature "state";

# used for loading chronicle config file which contains connection information
use YAML::XS;
use JSON;
use DBI;
use DateTime;
use Date::Utility;
use BOM::Plarform::RedisReplicated;
use DBIx::TransactionManager::Distributed;

use Data::Chronicle::Reader;
use Data::Chronicle::Writer;

# Used for any writes to the Chronicle DB
my $writer_instance;
# Historical instance will be used for fetching historical chronicle data (e.g. back-testing)
my $historical_instance;
# Live instance will be used for live pricing (normal website operations)
my $live_instance;
# NOTE - if you add other instances, see L</_dbh_changed>

sub get_chronicle_writer {
    state $redis = BOM::Plarform::RedisReplicated::redis_write();

    $writer_instance //= Data::Chronicle::Writer->new(
        cache_writer => $redis,
        db_handle    => _dbh(),
    );

    return $writer_instance;
}

sub get_chronicle_reader {
    #if for_date is specified, then this chronicle_reader will be used for historical data fetching, so it needs a database connection
    my $for_date = shift;
    state $redis = BOM::Plarform::RedisReplicated::redis_read();

    if ($for_date) {
        $historical_instance //= Data::Chronicle::Reader->new(
            cache_reader => $redis,
            db_handle    => _dbh(),
        );

        return $historical_instance;
    }

    #if for_date is not specified, we are doing live_pricing, so no need to send database handler
    $live_instance //= Data::Chronicle::Reader->new(
        cache_reader => $redis,
    );

    return $live_instance;
}

=head3 C<< set("category1", "name1", $value1)  >>

Store a piece of data "value1" under key "category1::name1" in Pg and Redis.

=cut

sub set {
    my $category = shift;
    my $name     = shift;
    my $value    = shift;
    my $rec_date = shift;

    $rec_date //= Date::Utility->new();

    die "Cannot store undefined values in Chronicle!" unless defined $value;
    die "You can only store hash-ref or array-ref in Chronicle!" unless (ref $value eq 'ARRAY' or ref $value eq 'HASH');

    $value = JSON::to_json($value);

    my $key = $category . '::' . $name;
    BOM::Plarform::RedisReplicated::redis_write()->set($key, $value);
    _archive($category, $name, $value, $rec_date) if _dbh();

    return 1;
}

=head3 C<< my $data = get("category1", "name1") >>

Query for the latest data under "category1::name1" from Redis.

=cut

sub get {
    my $category = shift;
    my $name     = shift;

    my $key         = $category . '::' . $name;
    my $cached_data = BOM::Plarform::RedisReplicated::redis_read()->get($key);

    return JSON::from_json($cached_data) if defined $cached_data;
    # FIXME assuming scalar context here, very dangerous - audit all callers
    # and replace with return undef;
    return;
}

=head3 C<< my $data = get_for("category1", "name1", 1447401505) >>

Query Pg archive for the data under "category1::name1" at or exactly before the given epoch/Date::Utility.

=cut

sub get_for {
    my $category = shift;
    my $name     = shift;
    my $date_for = shift;    #epoch or Date::Utility

    my $db_timestamp = Date::Utility->new($date_for)->db_timestamp;

    my $db_data = _dbh()->selectall_hashref(q{SELECT * FROM chronicle where category=? and name=? and timestamp<=? order by timestamp desc limit 1},
        'id', {}, $category, $name, $db_timestamp);

    return if not %$db_data;

    my $id_value = (sort keys %{$db_data})[0];
    my $db_value = $db_data->{$id_value}->{value};

    return JSON::from_json($db_value);
}

sub get_for_period {
    my $category = shift;
    my $name     = shift;
    my $start    = shift;    #epoch or Date::Utility
    my $end      = shift;    #epoch or Date::Utility

    my $start_timestamp = Date::Utility->new($start)->db_timestamp;
    my $end_timestamp   = Date::Utility->new($end)->db_timestamp;

    my $db_data =
        _dbh()->selectall_hashref(q{SELECT * FROM chronicle where category=? and name=? and timestamp<=? AND timestamp >=? order by timestamp desc},
        'id', {}, $category, $name, $end_timestamp, $start_timestamp);

    return if not %$db_data;

    my @result;

    for my $id_value (keys %$db_data) {
        my $db_value = $db_data->{$id_value}->{value};

        push @result, JSON::from_json($db_value);
    }

    return \@result;
}

sub _archive {
    my $category = shift;
    my $name     = shift;
    my $value    = shift;
    my $rec_date = shift;

    # In unit tests, we will use Test::MockTime to force Chronicle to store hostorical data
    my $db_timestamp = $rec_date->db_timestamp;

    return _dbh()->prepare(<<'SQL')->execute($category, $name, $value, $db_timestamp);
WITH ups AS (
    UPDATE chronicle
       SET value=$3
     WHERE timestamp=$4
       AND category=$1
       AND name=$2
 RETURNING *
)
INSERT INTO chronicle (timestamp, category, name, value)
SELECT $4, $1, $2, $3
 WHERE NOT EXISTS (SELECT * FROM ups)
SQL
}

# According to discussions made, we are supposed to support "Redis only" installation where there is not Pg.
# The assumption is that we have Redis for all data which is important for continutation of our services
# We also have Pg for an archive of data used later for non-live services (e.g back-testing, auditing, ...)
# And in case for any reason, Redis has problems, we will need to re-populate its information not from Pg
# But by re-running population scripts
my $dbh;

my $pid = $$;

sub _dbh {
    # Silently ignore if there is not configuration for Pg chronicle (e.g. in Travis)
    return undef if not defined _config()->{chronicle};

    # Our reconnection logic here is quite simple: assume that a PID change means we need to
    # reconnect to the database. This also assumes that DBI will reconnect as necessary when
    # the remote server is restarted or the network drops for any other reason.
    # There is a more advanced Perl module for handling this - https://metacpan.org/pod/DBIx::Connector
    # - but the code there is more complicated, including features such as threads support and
    # Apache::DBI, and so far there hasn't been a compelling reason to consider switching.
    # Note that switching DBIx::Connector's ->ping behaviour would not be much help for Data::Chronicle::*
    # handles, we'd need to update Data::Chronicle itself to use DBIx::Connector to get that benefit.
    return $dbh if $dbh and $$ == $pid;
    DBIx::TransactionManager::Distributed::release_dbh(chronicle => $dbh) if $dbh;
    $pid = $$;
    $dbh = DBI->connect(
        '' . _dbh_dsn(),
        # User and password are part of the DSN
        '', '',
        {
            RaiseError        => 1,
            pg_server_prepare => 0,
        });
    DBIx::TransactionManager::Distributed::register_dbh(chronicle => $dbh);
    _dbh_changed();
    return $dbh;
}

sub _dbh_dsn {
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    return "dbi:Pg:dbname=chronicle$db_postfix;port=6432;host=/var/run/postgresql;user=write";
}

=head2 _dbh_changed

Used to ensure we will refresh anything that uses a chronicle database handle
the next time an instance is requested.

Note that any new Chronicle instances we add to this code must also be listed here
if you want reconnection to work as expected.

=cut

sub _dbh_changed {
    undef $writer_instance;
    undef $historical_instance;
    undef $live_instance;
    return;
}

my $config;

BEGIN {
    $config = YAML::XS::LoadFile('/etc/rmg/chronicle.yml');
}

sub _config {
    return $config;
}

sub _redis_write {
    warn "Chronicle::_redis_write is deprecated. Please, use RedisReplicated::redis_write";
    return BOM::Plarform::RedisReplicated::redis_write;
}

1;
