package BOM::Test::Data::Utility::FeedTestDatabase;
use strict;
use warnings;

use BOM::Test;
use Cache::RedisDB;
use MooseX::Singleton;
use Postgres::FeedDB;
use Postgres::FeedDB::Spot::Tick;
use Postgres::FeedDB::Spot::OHLC;
use File::Basename;
use Try::Tiny;
use YAML::XS qw(LoadFile);
use Sereal::Encoder;
use BOM::Config::RedisReplicated;

use base qw( Exporter );
our @EXPORT_OK = qw( setup_ticks );

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

my $encoder = Sereal::Encoder->new({
    canonical => 1,
});

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
    my ($table, $currency_pair, $date) = @_;
    my $file_name = "$date.$table.copy";
    # get this file's path, not the path of script that is using this function
    # this is to make the path below a relative path
    my $feed_file  = dirname(__FILE__) . "/../../../../../feed/combined/$currency_pair/$file_name";
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    my $db         = "feed$db_postfix";

    my $command = qq{psql -p 5433 postgresql://write:mRX1E3Mi00oS8LG\@localhost/$db -c "\\COPY $table FROM '$feed_file'"};
    return 1 if system($command) == 0;
    warn "setup ticks failed: $?\n";
    return;
}

sub create_realtime_tick {
    my $args = shift;

    die 'args must be a hash reference' if ref $args ne 'HASH';

    return Cache::RedisDB->set_nw('QUOTE', $args->{underlying}, $args);
}

sub create_historical_ticks {
    my $args = shift;

    my $tick_data          = LoadFile('/home/git/regentmarkets/bom-test/data/suite_ticks.yml')->{DECIMATE_frxUSDJPY_15s_DEC};
    my $default_underlying = $args->{underlying} // 'frxUSDJPY';
    my $default_start      = $args->{epoch} // time;
    my $key                = "DECIMATE_" . $default_underlying . "_15s_DEC";

    my $redis = BOM::Config::RedisReplicated::redis_write();
    for my $tick (@$tick_data) {
        $tick->{epoch} = $tick->{decimate_epoch} = $default_start;
        $redis->zadd($key, $tick->{epoch}, $encoder->encode($tick));
        $default_start -= 15;
    }

    return;
}

sub create_redis_ticks {
    my $args = shift;

    my $ticks             = $args->{ticks}      // die 'ticks are required.';
    my $underlying_symbol = $args->{underlying} // die 'underlying is required.';
    my $type  = $args->{type} eq 'decimate' ? '_15s_DEC' : '_31m_FULL';
    my $redis = BOM::Config::RedisReplicated::redis_write();
    my $key   = 'DECIMATE_' . $underlying_symbol . $type;

    $redis->zadd($key, $_->{epoch}, $encoder->encode($_)) for @$ticks;

    return;
}

sub create_tick {
    my ($args, $create_redis_tick) = @_;

    $create_redis_tick //= 1;

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

    # create tick in database
    my $tick = Postgres::FeedDB::Spot::Tick->new(\%defaults);

    if ($args->{create_redis_tick}) {
        # create redis ticks
        $defaults{count}          = 1;
        $defaults{decimate_epoch} = $defaults{epoch};

        create_redis_ticks({
            underlying => $defaults{underlying},
            type       => 'full',
            ticks      => [\%defaults],
        });
    }

    return $tick;
}

=head2 flush_and_create_ticks

Flush feed database and create ticks

=cut

sub flush_and_create_ticks {
    my @ticks = @_;

    Cache::RedisDB->flushall;
    my $redis = BOM::Config::RedisReplicated::redis_write();
    $redis->del($_) for @{$redis->keys('*DEC*')};
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;

    for my $tick (@ticks) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            quote      => $tick->[0],
            epoch      => $tick->[1],
            underlying => $tick->[2],
        });
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
            $sth->bind_param(7, $defaults{official});
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
