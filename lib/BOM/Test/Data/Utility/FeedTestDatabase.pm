package BOM::Test::Data::Utility::FeedTestDatabase;

use strict;
use warnings;

use MooseX::Singleton;
use BOM::Platform::Runtime;
use BOM::Database::FeedDB;
use Try::Tiny;

use base qw( Exporter );
our @EXPORT_OK = qw( setup_ticks );

sub _db_name {
    return 'feed';
}

sub _db_migrations_dir {
    return 'feeddb';
}

sub _build__connection_parameters {
    return {
        database => 'feed',
        driver   => 'Pg',
        host     => 'localhost',
        port     => '5433',
        user     => 'postgres',
        password => 'mRX1E3Mi00oS8LG',
    };
}

sub _post_import_operations {
    my $self = shift;

    return;
}

sub truncate_tables {
    my $self   = shift;
    my @tables = qw(tick ohlc_minutely ohlc_hourly ohlc_daily ohlc_status);

    my $dbh = $self->db_handler($self->_db_name);
    try {
        foreach my $table (@tables) {
            $dbh->do('truncate table feed.' . $table);
        }
    };

    return;
}

sub setup_ticks {
    my $file      = shift;
    my $feed_file = '/home/git/regentmarkets/bom-test/feed/combined/' . $file;

    my $command;
    $command = "PGPASSWORD=mRX1E3Mi00oS8LG";
    $command .= " /usr/lib/postgresql/9.1/bin/pg_restore -d feed";
    $command .= " -Fc -a -p 5433";
    $command .= " -U write";
    $command .= " -h localhost ";
    $command .= " $feed_file";

    my $exit_status = system($command);
    if ($exit_status == 0) {

        # upon success
        return 1;
    }
    return;
}

sub create_ohlc_daily {
    my $args = shift;

    my %defaults = (
        underlying => 'frxUSDJPY',
        epoch      => 1325462400,    # Sun, 02 Jan 2012 00:00:00 GMT
        open       => 76.8996,
        high       => 76.9001,
        low        => 76.8344,
        close      => 76.8633,
        official   => 1,
    );

    # any modify args were specified?
    for (keys %$args) {
        $defaults{$_} = $args->{$_};
    }

    # date for database
    my $ts = Date::Utility->new($defaults{epoch})->datetime_yyyymmdd_hhmmss;

    my $dbh = BOM::Database::FeedDB::write_dbh;

    my $tick_sql = <<EOD;
INSERT INTO feed.ohlc_daily(underlying, ts, open, high, low, close, official)
    VALUES(?, ?, ?, ?, ?, ?, ?)
EOD

    my $sth = $dbh->prepare($tick_sql);
    $sth->bind_param(1, $defaults{underlying});
    $sth->bind_param(2, $ts);
    $sth->bind_param(3, $defaults{open});
    $sth->bind_param(4, $defaults{high});
    $sth->bind_param(5, $defaults{low});
    $sth->bind_param(6, $defaults{close});
    $sth->bind_param(7, 1);
    $sth->execute();

    delete $defaults{underlying};
    return BOM::Market::Data::OHLC->new(\%defaults);
}

with 'BOM::Test::Data::Utility::TestDatabaseSetup';

no Moose;
__PACKAGE__->meta->make_immutable;

## no critic (Variables::RequireLocalizedPunctuationVars)
sub import {
    my ($class, $init) = @_;
    __PACKAGE__->instance->prepare_unit_test_database
        if $init && $init eq ':init';
    return;
}

1;
