package BOM::Test::Data::Utility::FeedTestDatabase;

use strict;
use warnings;

use MooseX::Singleton;
use BOM::Platform::Runtime;
use BOM::Database::FeedDB;
use BOM::Market::Data::Tick;
use Try::Tiny;

use base qw( Exporter );
our @EXPORT_OK = qw( setup_ticks );

sub _db_name {
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    return "feed$db_postfix";
}

sub _db_migrations_dir {
    return 'feeddb';
}

sub _build__connection_parameters {
    my $self = shift;
    return {
        database       => $self->_db_name,
        driver         => 'Pg',
        host           => 'localhost',
        port           => '5433',
        user           => 'postgres',
        password       => 'mRX1E3Mi00oS8LG',
        pgbouncer_port => '6433',
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
    my $file       = shift;
    my $feed_file  = '/home/git/regentmarkets/bom-test/feed/combined/' . $file;
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    my $db         = 'feed' . $db_postfix;
    my $command;
    $command = "PGPASSWORD=mRX1E3Mi00oS8LG";
    $command .= " /usr/lib/postgresql/9.1/bin/pg_restore -d $db";
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

sub create_tick {
    my $args = shift;

    my %defaults = (
        underlying => 'frxUSDJPY',
        epoch      => 1325462400,    # Sun, 02 Jan 2012 00:00:00 GMT
        quote      => 76.8996,
        bid        => 76.9010,
        ask        => 76.5030,
    );

    # any modify args were specified?
    for (keys %$args) {
        $defaults{$_} = $args->{$_};
    }

    # table for tick
    _create_table_for_date(Date::Utility->new($defaults{epoch}));

    # date for database
    my $ts = Date::Utility->new($defaults{epoch})->datetime_yyyymmdd_hhmmss;

    my $dbh = BOM::Database::FeedDB::write_dbh;
    $dbh->{PrintWarn}  = 0;
    $dbh->{PrintError} = 0;
    $dbh->{RaiseError} = 1;

    my $tick_sql = <<EOD;
INSERT INTO feed.tick(underlying, ts, bid, ask, spot)
    VALUES(?, ?, ?, ?, ?)
EOD

    my $sth = $dbh->prepare($tick_sql);
    $sth->bind_param(1, $defaults{underlying});
    $sth->bind_param(2, $ts);
    $sth->bind_param(3, $defaults{bid});
    $sth->bind_param(4, $defaults{ask});
    $sth->bind_param(5, $defaults{quote});
    $sth->execute();

    return BOM::Market::Data::Tick->new(\%defaults);
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

sub _create_table_for_date {
    my $date = shift;
    my $dbh  = BOM::Database::FeedDB::write_dbh;

    my $table_name = 'tick_' . $date->year . '_' . $date->month;
    my $stmt       = $dbh->prepare(' select count(*) from pg_tables where schemaname=\'feed\' and tablename = \'' . $table_name . '\'');
    $stmt->execute;
    my $table_present = $stmt->fetchrow_arrayref;

    if ($table_present->[0] < 1) {
        my $db_postfix = $ENV{DB_POSTFIX} // '';
        my $db         = 'feed' . $db_postfix;
        my $dbh        = DBI->connect("dbi:Pg:dbname=$db;host=localhost;port=5433", 'postgres', 'mRX1E3Mi00oS8LG') or croak $DBI::errstr;

        # This operation is bound to raise an warning about how index was created.
        # We can ignore it.
        $dbh->{PrintWarn}  = 0;
        $dbh->{PrintError} = 0;
        $dbh->{RaiseError} = 1;

        my $partition_date = Date::Utility->new($date->epoch - (($date->day_of_month - 1) * 86400));
        $dbh->do(
            ' CREATE TABLE feed.' . $table_name . '(
            PRIMARY KEY (underlying, ts),
            CHECK(ts>= \''
                . $partition_date->date_yyyymmdd . '\' and ts<\'' . $partition_date->date_yyyymmdd . '\'::DATE + interval \'1 month\'),
            CHECK(DATE_TRUNC(\'second\', ts) = ts)
        )
        INHERITS (feed.tick)'
        );
        $dbh->do('GRANT SELECT ON feed.' . $table_name . ' TO read');

        $dbh->do('GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER ON feed.' . $table_name . ' TO write');
    }

    return;
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
