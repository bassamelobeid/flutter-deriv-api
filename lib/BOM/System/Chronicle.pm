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

Given a category, name and value stores the given value (after JSONifying) in Redis and PostgreSQL database under "category::name" group and also stored current
system time as the timestamp for the data (Which can be used for future retrieval if we want to get data as of a specific time)

=item C<get>

Given a category and name returns the latest version of the data according to current Redis cache (If data is not found in the cache falls back to PostgresSQL)

=item C<get_for>

Given a category, name and timestamp returns version of data under "category::name" as of the given date (using a DB lookup).

=back

=head1 Example

```
my $d = get_some_data();

#store data into Chronicle
BOM::System::Chronicle::set("vol_surface", "frxUSDJPY", $d);

#retrieve latest data stored for "vol_surface" and "frxUSDJPY"
my $dt = BOM::System::Chronicle::set("vol_surface", "frxUSDJPY");

#find vol_surface for frxUSDJPY as of Jan 15, 2015.
my $some_old_data = get_for("vol_surface", "frxUSDJPY", 
                            DateTime::Format::Pg->format_timestamp(DateTime->new(year => 2015, month => 1, day => 10)));
```

=head1 Future directions

As we continue migrating new data types to this model, there will probably be more changes to this module to make it fit for our requirements in Quant code-base.

=cut

use strict;
use warnings;

#we cache connections to Redis and Postgres so we use state feature.
use feature "state";

use YAML::XS;
use JSON;
use RedisDB;
use DBI;
use DateTime::Format::Pg;
use DateTime;

sub set {
    my $category = shift;
    my $name     = shift;
    my $value    = shift;

    $value = JSON::to_json($value);

    my $key = $category . '::' . $name;
    _redis_write()->set($key, $value);
    _archive($category, $name, $value) if _dbh();

    return 1;
}

sub get {
    my $category = shift;
    my $name     = shift;

    my $key         = $category . '::' . $name;
    my $cached_data = _redis_read()->get($key);

    if ($cached_data) {
        return JSON::from_json($cached_data);
    }

    my $db_data = get_for($category, $name, DateTime::Format::Pg->format_timestamp(DateTime->now()));

    if (defined $db_data && keys %{$db_data}) {
        my $id_value = (sort keys %{$db_data})[0];
        my $db_value = $db_data->{$id_value}->{value};

        _redis_write()->set($key, $db_value);

        return JSON::from_json($db_value);
    }
}

sub get_for {
    my $category = shift;
    my $name     = shift;
    my $date_for = shift;

    return _dbh()->selectall_hashref(q{SELECT * FROM chronicle where category=? and name=? and timestamp<=? order by timestamp desc limit 1},
        'id', {}, $category, $name, $date_for);
}

sub _archive {
    my $category = shift;
    my $name     = shift;
    my $value    = shift;

    return _dbh()->prepare(<<'SQL')->execute($category, $name, $value);
WITH ups AS (
    UPDATE chronicle
       SET value=$3
     WHERE timestamp=DATE_TRUNC('second', now())
       AND category=$1
       AND name=$2
 RETURNING *
)
INSERT INTO chronicle (timestamp, category, name, value)
SELECT DATE_TRUNC('second', now()), $1, $2, $3
 WHERE NOT EXISTS (SELECT * FROM ups)
SQL
}

sub _redis_write {
    state $redis_write = RedisDB->new(
        host     => _config()->{write}->{host},
        port     => _config()->{write}->{port},
        password => _config()->{write}->{password});
    return $redis_write;
}

sub _redis_read {
    state $redis_read = RedisDB->new(
        host     => _config()->{read}->{host},
        port     => _config()->{read}->{port},
        password => _config()->{read}->{password});
    return $redis_read;
}

sub _dbh {
    return if not defined _config()->{chronicle};

    state $dbh = DBI->connect_cached(
        "dbi:Pg:dbname=chronicle;port=5437;host=" . _config()->{chronicle}->{ip},
        "write",
        _config()->{chronicle}->{password},
        {
            RaiseError => 1,
        });
    return $dbh;
}

sub _config {
    state $config = YAML::XS::LoadFile('/etc/chronicle.yml');
    return $config;
}

1;
