package BOM::Platform::Chronicle;

=head1 NAME

BOM::Platform::Chronicle - Provides efficient data storage for volatile and time-based data

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

There are two important methods this module provides:

=over 4

=item C<get_chronicle_reader>

Returns a Data::Chronicle::Reader object.

=item C<get_chronicle_writer>

Returns a Data::Chronicle::Writer object.

=back

=head1 Example

    use BOM::Platform::Chronicle;

    my $d = get_some_data();
    my $reader = BOM::Platform::Chronicle::get_chronicle_reader();
    my $writer = BOM::Platform::Chronicle::get_chronicle_writer();

    #store data into Chronicle
    writer->set("vol_surface", "frxUSDJPY", $d);

    #retrieve latest data stored for "vol_surface" and "frxUSDJPY"
    my $dt = $reader->get("vol_surface", "frxUSDJPY");

    #find vol_surface for frxUSDJPY as of a specific date
    my $some_old_data = $reader->get_for("vol_surface", "frxUSDJPY", $epoch1);

=cut

use strict;
use warnings;

# we cache connection to Redis, so we use state feature.
use feature "state";

# used for loading chronicle config file which contains connection information
use YAML::XS;
use JSON;
use DBIx::Connector::Pg;
use DateTime;
use Date::Utility;
use BOM::Platform::RedisReplicated;

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
    state $redis = BOM::Platform::RedisReplicated::redis_write();

    $writer_instance //= Data::Chronicle::Writer->new(
        publish_on_set => 1,
        cache_writer   => $redis,
        dbic           => dbic(),
    );

    return $writer_instance;
}

sub get_chronicle_reader {
    #if for_date is specified, then this chronicle_reader will be used for historical data fetching, so it needs a database connection
    my $for_date = shift;
    state $redis = BOM::Platform::RedisReplicated::redis_read();

    if ($for_date) {
        $historical_instance //= Data::Chronicle::Reader->new(
            cache_reader => $redis,
            dbic         => dbic(),
        );

        return $historical_instance;
    }

    #if for_date is not specified, we are doing live_pricing, so no need to send database handler
    $live_instance //= Data::Chronicle::Reader->new(
        cache_reader => $redis,
    );

    return $live_instance;
}

# According to discussions made, we are supposed to support "Redis only" installation where there is not Pg.
# The assumption is that we have Redis for all data which is important for continutation of our services
# We also have Pg for an archive of data used later for non-live services (e.g back-testing, auditing, ...)
# And in case for any reason, Redis has problems, we will need to re-populate its information not from Pg
# But by re-running population scripts
my $dbic;

sub dbic {
    # Silently ignore if there is not configuration for Pg chronicle (e.g. in Travis)
    return undef if not defined _config()->{chronicle};
    $dbic //= DBIx::Connector::Pg->new(
        _dbh_dsn(),
        # User and password are part of the DSN
        '', '',
        {
            RaiseError        => 1,
            pg_server_prepare => 0,
        });
    $dbic->mode('fixup');
    return $dbic;
}

sub _dbh_dsn {
    return "dbi:Pg:service=chronicle";
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
    return BOM::Platform::RedisReplicated::redis_write;
}

1;
