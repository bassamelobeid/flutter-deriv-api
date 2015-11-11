package BOM::Test::Data::Utility::Feed;

use BOM::Database::FeedDB;
use BOM::Market::Data::Tick;
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

sub _create_table_for_date {
    my $date = shift;
    my $dbh  = BOM::Database::FeedDB::write_dbh;

    my $table_name = 'tick_' . $date->year . '_' . $date->month;
    my $stmt       = $dbh->prepare(' select count(*) from pg_tables where schemaname=\'feed\' and tablename = \'' . $table_name . '\'');
    $stmt->execute;
    my $table_present = $stmt->fetchrow_arrayref;

    if ($table_present->[0] < 1) {
        my $dbh = DBI->connect('dbi:Pg:dbname=feed;host=localhost;port=5433', 'postgres', 'letmein') or croak $DBI::errstr;

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
1;

