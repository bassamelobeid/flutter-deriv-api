package BOM::Test::Data::Utility::FeedTestDatabase;

use strict;
use warnings;

use BOM::Test;
use Cache::RedisDB;
use MooseX::Singleton;
use Postgres::FeedDB;
use Postgres::FeedDB::Spot::Tick;
use Postgres::FeedDB::Spot::OHLC;
use Try::Tiny;
use YAML::XS qw(LoadFile);
use Sereal::Encoder;
use BOM::Platform::RedisReplicated;

use base qw( Exporter );
our @EXPORT_OK = qw( setup_ticks );

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub _db_name {
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    return "feed$db_postfix";
}

sub _db_migrations_dir {
    return '/home/git/regentmarkets/bom-postgres-feeddb/config/sql/';
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
        pg_version     => '9.5',
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

    my $error = `$command 2>&1`;
    return 1 if $? >> 8 == 0;
    warn "setup ticks failed: $error";

    return;
}

sub create_realtime_tick {
    my $args = shift;

    die 'args must be a hash reference' if ref $args ne 'HASH';

    return Cache::RedisDB->set_nw('QUOTE', $args->{underlying}, $args);
}

sub create_historical_ticks {
    my $args = shift;

    my $tick_data = LoadFile('/home/git/regentmarkets/bom-test/data/suite_ticks.yml')->{DECIMATE_frxUSDJPY_15s_DEC};
    my $encoder   = Sereal::Encoder->new({
        canonical => 1,
    });

    my $default_underlying = $args->{underlying} // 'frxUSDJPY';
    my $default_start      = $args->{epoch}      // time;
    my $key                = "DECIMATE_" . $default_underlying . "_15s_DEC";

    my $redis = BOM::Platform::RedisReplicated::redis_write();
    for my $tick (@$tick_data) {
        $tick->{epoch} = $tick->{decimate_epoch} = $default_start;
        $redis->zadd($key, $tick->{epoch}, $encoder->encode($tick));
        $default_start -= 15;
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

    my $tick_sql = <<EOD;
INSERT INTO feed.tick(underlying, ts, bid, ask, spot)
    VALUES(?, ?, ?, ?, ?)
EOD

    my $dbic = Postgres::FeedDB::write_dbic;
    $dbic->run(
        sub {
            my $sth = $_->prepare($tick_sql);
            $sth->bind_param(1, $defaults{underlying});
            $sth->bind_param(2, $ts);
            $sth->bind_param(3, $defaults{bid});
            $sth->bind_param(4, $defaults{ask});
            $sth->bind_param(5, $defaults{quote});
            $sth->execute();

        });

    return Postgres::FeedDB::Spot::Tick->new(\%defaults);
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

    my $dbic = Postgres::FeedDB::write_dbic;

    my $tick_sql = <<EOD;
INSERT INTO feed.ohlc_daily(underlying, ts, open, high, low, close, official)
    VALUES(?, ?, ?, ?, ?, ?, ?)
EOD
    $dbic->run(
        sub {
            my $sth = $_->prepare($tick_sql);
            $sth->bind_param(1, $defaults{underlying});
            $sth->bind_param(2, $ts);
            $sth->bind_param(3, $defaults{open});
            $sth->bind_param(4, $defaults{high});
            $sth->bind_param(5, $defaults{low});
            $sth->bind_param(6, $defaults{close});
            $sth->bind_param(7, 1);
            $sth->execute();
        });

    delete $defaults{underlying};
    return Postgres::FeedDB::Spot::OHLC->new(\%defaults);
}

sub _create_table_for_date {
    my $date = shift;
    my $dbic = Postgres::FeedDB::write_dbic;

    my $table_name = 'tick_' . $date->year . '_' . $date->month;

    my $table_present = $dbic->run(
        sub {
            my $stmt = $_->prepare(qq{select count(*) from pg_tables where schemaname='feed' and tablename = ?});
            $stmt->execute($table_name);
            return $stmt->fetchrow_arrayref;
        });

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
        my $date_str = $partition_date->date_yyyymmdd;
        $dbh->do(
            qq{CREATE TABLE feed.$table_name (
            PRIMARY KEY (underlying, ts),
            CHECK(ts>= ? and ts<?::DATE + interval '1 month'),
            CHECK(DATE_TRUNC('second', ts) = ts)
        )
        INHERITS (feed.tick)}, undef, $date_str, $date_str
        );
        $dbh->do("GRANT SELECT ON feed.$table_name  TO read");

        $dbh->do("GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER ON feed.$table_name TO write");
    }

    return;
}

with 'BOM::Test::Data::Utility::TestDatabaseSetup';

no Moose;
__PACKAGE__->meta->make_immutable;

## no critic (Variables::RequireLocalizedPunctuationVars)
sub import {
    my (undef, $init) = @_;
    __PACKAGE__->instance->prepare_unit_test_database
        if $init && $init eq ':init';
    return;
}

1;
