package BOM::System::Chronicle;

=head1 NAME

BOM::System::Chronicle - Provides efficient data storage for volatile and time-based data

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
 BOM::System::Chronicle::set("vol_surface", "frxUSDJPY", $d);

 #retrieve latest data stored for "vol_surface" and "frxUSDJPY"
 my $dt = BOM::System::Chronicle::set("vol_surface", "frxUSDJPY");

 #find vol_surface for frxUSDJPY as of a specific date
 my $some_old_data = get_for("vol_surface", "frxUSDJPY", $epoch1);

=head1 Future directions

As we continue migrating new data types to this model, there will probably be more changes to this module to make it fit for our requirements in Quant code-base.

=cut

use strict;
use warnings;

#we cache connections to Redis and Postgres so we use state feature.
use feature "state";

#used for loading chronicle config file which contains connection information
use YAML::XS;
use JSON;
use RedisDB;
use DBI;
use DateTime;
use Date::Utility;

=head3 C<< set("category1", "name1", $value1)  >>

Store a piece of data "value1" under key "category1::name1" in Pg and Redis.

=cut

sub set {
    my $category = shift;
    my $name     = shift;
    my $value    = shift;

    die "Cannot store undefined values in Chronicle!" unless defined $value;
    die "You can only store hash-ref or array-ref in Chronicle!" unless (ref $value eq 'ARRAY' or ref $value eq 'HASH');

    $value = JSON::to_json($value);

    my $key = $category . '::' . $name;
    _redis_write()->set($key, $value);
    _archive($category, $name, $value) if _dbh();

    return 1;
}

=head3 C<< my $data = get("category1", "name1") >>

Query for the latest data under "category1::name1" from Redis.

=cut

sub get {
    my $category = shift;
    my $name     = shift;

    my $key         = $category . '::' . $name;
    my $cached_data = _redis_read()->get($key);

    return JSON::from_json($cached_data) if defined $cached_data;
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

sub _archive {
    my $category = shift;
    my $name     = shift;
    my $value    = shift;

    # In unit tests, we will use Test::MockTime to force Chronicle to store hostorical data
    my $db_timestamp = Date::Utility->new()->db_timestamp;

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

sub _redis_write {
    state $redis_write = RedisDB->new(
        timeout => 10,
        host    => _config()->{write}->{host},
        port    => _config()->{write}->{port},
        (_config()->{write}->{password} ? ('password', _config()->{write}->{password}) : ()));

    return $redis_write;
}

sub _redis_read {
    state $redis_read = RedisDB->new(
        timeout => 10,
        host    => _config()->{read}->{host},
        port    => _config()->{read}->{port},
        (_config()->{read}->{password} ? ('password', _config()->{read}->{password}) : ()));

    return $redis_read;
}

#According to discussions made, we are supposed to support "Redis only" installation where there is not Pg.
#The assumption is that we have Redis for all data which is important for continutation of our services
#We also have Pg for an archive of data used later for non-live services (e.g back-testing, auditing, ...)
#And in case for any reason, Redis has problems, we will need to re-populate its information not from Pg
#But by re-running population scripts
sub _dbh {
    #silently ignore if there is not configuration for Pg chronicle (e.g. in Travis)
    return if not defined _config()->{chronicle};

    state $dbh = DBI->connect_cached(
        "dbi:Pg:dbname=chronicle-write;port=6432;host=/var/run/postgresql",
        "write",
        '',
        {
            RaiseError => 1,
        });
    return $dbh;
}

sub _config {
    state $config = YAML::XS::LoadFile('/etc/rmg/chronicle.yml');
    return $config;
}

1;
