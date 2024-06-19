package BOM::Config::Chronicle;

use strict;
use warnings;

=head1 NAME

C<BOM::Config::Chronicle> - Provides efficient data storage for volatile and time-based data

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

    use BOM::Config::Chronicle;

    my $d = get_some_data();
    my $reader = BOM::Config::Chronicle::get_chronicle_reader();
    my $writer = BOM::Config::Chronicle::get_chronicle_writer();

    #store data into Chronicle
    writer->set("vol_surface", "frxUSDJPY", $d);

    #retrieve latest data stored for "vol_surface" and "frxUSDJPY"
    my $dt = $reader->get("vol_surface", "frxUSDJPY");

    #find vol_surface for frxUSDJPY as of a specific date
    my $some_old_data = $reader->get_for("vol_surface", "frxUSDJPY", $epoch1);

=cut

use DBIx::Connector;
use Date::Utility;
use BOM::Config::Redis;

use Data::Chronicle::Reader;
use Data::Chronicle::Writer;
use BOM::Config::AuditedChronicleWriter;

=head2 get_chronicle_writer

Get chronicle writer

Example:

    my $writer = BOM::Config::Chronicle::get_chronicle_writer();
    $chronicle_writer->set(
                'interest_rates',
                $symbol,
                {...},
                Date::Utility->new(),
            );

Returns a L<Data::Chronicle::Writer> object that can write to the redis cache
and config database.

=cut

sub get_chronicle_writer {
    return Data::Chronicle::Writer->new(
        publish_on_set => 1,
        cache_writer   => BOM::Config::Redis::redis_replicated_write(),
        dbic           => dbic(),
    );
}

=head2 get_audited_chronicle_writer

Get audited chronicle writer

Takes the following argument(s) as parameters:

=over 4

=item * C<staff> - The type of audit survey done when writer was called

=back

Example:

    my $writer = BOM::Config::Chronicle::get_audited_chronicle_writer('P2P Daily Maintenance');

Returns a L<BOM::Config::AuditedChronicleWriter> object that can write to the redis cache
and config database

Same as L</get_chronicle_writer>, but this one will add a C<staff> field to the data stored in chronicle

=cut

sub get_audited_chronicle_writer {
    my ($staff) = @_;

    die 'You must specify the staff name' unless $staff;

    return BOM::Config::AuditedChronicleWriter->new(
        publish_on_set => 1,
        cache_writer   => BOM::Config::Redis::redis_replicated_write(),
        dbic           => dbic(),
        staff          => $staff
    );
}

=head2 get_chronicle_reader

Get chronicle writer

Takes the following argument(s):

=over 4

=item * C<$for_date> - The date used from which historical data needs to be fetched

=back

Example:

    my $reader = BOM::Config::Chronicle::get_chronicle_reader();

Returns a L<Data::Chronicle::Reader> object that can read from the redis cache
and config database.

if C<$for_date> is specified, then this chronicle_reader will be used for historical
data fetching, so it needs a database connection.

=cut

sub get_chronicle_reader {
    my $for_date = shift;
    my $redis    = BOM::Config::Redis::redis_replicated_read();

    if ($for_date) {
        return Data::Chronicle::Reader->new(
            cache_reader => $redis,
            dbic         => dbic(),
        );
    }

    #if for_date is not specified, we are doing live_pricing, so no need to send database handler
    return Data::Chronicle::Reader->new(
        cache_reader => $redis,
    );
}

my $dbic;

=head2 dbic

Get the PostgresSQL Database connection instance for config database.

Example:

    my $dbic = BOM::Config::Chronicle::dbic();
    my $rows = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT * FROM get_app_settings_history(?, ?, ?)", {Slice => {}}, $setting, $limit + 1, $offset);
        });

Returns a L<DBIx::Connector> singleton that provides connection instance
based on pg_service.conf credentials.
Returns L<undef> if no configuration is provided.

According to discussions made, we are supposed to support "Redis only" installation where there is no Pg.
The assumption is that we have Redis for all data which is important for continutation of our services
We also have Pg for an archive of data used later for non-live services (e.g back-testing, auditing, ...)
And in case for any reason, Redis has problems, we will need to re-populate its information not from Pg
But by re-running population scripts

=cut

sub dbic {
    # Silently ignore if there is not configuration for Pg chronicle (e.g. in Travis)
    return undef if not defined $ENV{PGSERVICEFILE} and not -e $ENV{HOME} . '/.pg_service.conf';
    $dbic //= DBIx::Connector->new(
        _dbic_dsn(),
        # User and password are part of the DSN
        '', '',
        {
            RaiseError        => 1,
            pg_server_prepare => 0,
        });
    $dbic->mode('fixup');
    return $dbic;
}

=head2 clear_connections

clears C<$dbic> object

Example:

    BOM::Config::Chronicle::clear_connections();

uninitializes the database connection instance.

=cut

sub clear_connections {
    $dbic = undef;
    return;
}

sub _dbic_dsn {
    return "dbi:Pg:service=chronicle";
}

1;
