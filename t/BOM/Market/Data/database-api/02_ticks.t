#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 13;
use Test::Exception;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Quant::Framework::Spot::DatabaseAPI;
use DateTime;
use Date::Utility;

use Quant::Framework::Spot::DatabaseAPI;
my $dbh = BOM::Database::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'prepare ticks' => sub {
    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 15,
            hour   => 12,
            minute => 12,
            second => 1
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 100.1,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick 1 - 2012-05-15 12:12:01';

    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 16,
            hour   => 12,
            minute => 12,
            second => 1
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 101.1,
            bid   => 101.8,
            ask   => 101.0
        });
    }
    'Tick 2 - 2012-05-16 12:12:01';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 16,
            hour  => 16
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 101.3,
            bid   => 101.5,
            ask   => 101.1
        });
    }
    'Tick 3 - 2012-05-16 16:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 16,
            hour  => 19
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 101.1,
            bid   => 101.3,
            ask   => 101.1
        });
    }
    'Tick 4 - 2012-05-16 19:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 17,
            hour  => 15
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 98.9,
            bid   => 100.8,
            ask   => 98.0
        });
    }
    'Tick 5 - 2012-05-17 15:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 18,
            hour  => 11
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 95.2,
            bid   => 93.0,
            ask   => 96.5
        });
    }
    'Tick 6 - 2012-05-18 11:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 18,
            hour  => 17
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 93.6,
            bid   => 93.7,
            ask   => 90.2
        });
    }
    'Tick 7 - 2012-05-18 17:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 19,
            hour  => 12
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 93.8,
            bid   => 94.2,
            ask   => 91.4
        });
    }
    'Tick 8 - 2012-05-19 12:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 20,
            hour  => 14
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 92.6,
            bid   => 93.5,
            ask   => 90.2
        });
    }
    'Tick 9 - 2012-05-20 14:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 20,
            hour  => 14
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxUSDAUD',
            epoch      => $date->epoch,
            quote      => 1.1,
            bid        => 1.12,
            ask        => 1.08
        });
    }
    'Tick 10 - frxUSDAUD 2012-05-20 14:00:00';
};

subtest 'Tick Fetch - Start-End - Simple' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ticks = $api->ticks_start_end({
        start_time => '2012-05-15 00:00:00',
        end_time   => '2012-05-20 23:00:00'
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks for 2012-05-15 00:00:00 to 2012-05-20 23:00:00 and';
    is scalar @$ticks, 9, 'All in all 9 ticks found';

    subtest 'Tick datatype' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            isa_ok $tick, 'Quant::Framework::Spot::Tick', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_tick = 99999999999;
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->epoch < $previous_tick, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_tick = $tick->epoch;
        }
    };

    subtest 'No frxUSDAUD' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->quote > 2, 'Tick at ' . $date->datetime_yyyymmdd_hhmmss . ' is frxUSDJPY';
        }
    };
};

subtest 'Tick Fetch - Start-End - Narrower' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $end_time  = '2012-05-16 19:00:00';
    my $end_epoch = Date::Utility->new($end_time)->epoch;
    my $ticks     = $api->ticks_start_end({
        start_time => '2012-05-15 00:00:00',
        end_time   => $end_time
    });
    isa_ok $ticks, 'ARRAY', "Got ticks for 2012-05-15 00:00:00 to $end_time and";
    is scalar @$ticks, 4, '4 ticks found, we are almost there';

    subtest 'Tick Quality' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->epoch <= $end_epoch, 'Tick ' . $date->datetime_yyyymmdd_hhmmss . ' <= 2012-05-16 19:00:00';
        }
    };

    is $ticks->[0]->epoch, $end_epoch, 'first OHLC time match';
};

subtest 'Tick Fetch - Start-End - Way off mark' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ticks = $api->ticks_start_end({
        start_time => '2012-03-15 00:00:00',
        end_time   => '2012-04-15 23:00:00'
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks for 2012-03-15 00:00:00 to 2012-04-15 23:00:00 and';
    is scalar @$ticks, 0, '0 ticks found';
};

subtest 'Tick Fetch - Start-End - Beserk User' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    throws_ok {
        warnings_like { my $ticks = $api->ticks_start_end({end_time => '2012-05-15 23:00:00'}); }
        qr/Error sanity_checks_start_end: start time\(<NULL>\) and end time\(1337644800\) should be provided/;
    }
    qr/sanity_checks_start_end/, 'No Start time - We don\'t entertain such queries 1';

    throws_ok {
        warnings_like { my $ticks = $api->ticks_start_end({start_time => '2012-05-22 00:00:00'}); }
        qr/Error sanity_checks_start_end: start time\(1337122800\) and end time\(<NULL>\) should be provided/;
    }
    qr/sanity_checks_start_end/, 'No End time - We don\'t entertain such queries 2';

    throws_ok {
        warnings_like { my $ticks = $api->ticks_start_end({start_time => '2012-05-22 00:00:00', end_time => '2012-05-15 23:00:00'}); }
        qr/Error sanity_checks_start_end: end time\(1337122800\) <= start time\(1337644800\)/;
    }
    qr/sanity_checks_start_end/, 'End time older than Start time - We don\'t entertain such queries 3';
};

subtest 'Tick Fetch - Start-Limit - Simple' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ticks = $api->ticks_start_limit({
        start_time => '2012-05-15 00:00:00',
        limit      => 10
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks from 2012-05-15 00:00:00 and';
    is scalar @$ticks, 9, 'All in all 9 ticks found';

    subtest 'Tick datatype' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            isa_ok $tick, 'Quant::Framework::Spot::Tick', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Ascending' => sub {
        my $previous_tick = 0;
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->epoch > $previous_tick, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_tick = $tick->epoch;
        }
    };

    subtest 'No frxUSDAUD' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->quote > 2, 'Tick at ' . $date->datetime_yyyymmdd_hhmmss . ' is frxUSDJPY';
        }
    };
};

subtest 'Tick Fetch - Start-Limit - Limit 2' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ticks = $api->ticks_start_limit({
        start_time => '2012-05-15 00:00:00',
        limit      => 2
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks from 2012-05-15 00:00:00 and';
    is scalar @$ticks, 2, 'All in all 2 ticks found';

    subtest 'Authenticity Checks' => sub {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 15,
            hour   => 12,
            minute => 12,
            second => 1
        );
        is $ticks->[0]->epoch, $date->epoch, 'Correct tick ' . $date->ymd . ' ' . $date->hms;

        $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 16,
            hour   => 12,
            minute => 12,
            second => 1
        );
        is $ticks->[1]->epoch, $date->epoch, 'Correct tick ' . $date->ymd . ' ' . $date->hms;
    };
};

subtest 'Tick Fetch - Start-Limit - Limit 2, but it can be any day' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ticks = $api->ticks_start_limit({
        start_time => '2011-03-01 00:00:00',
        limit      => 2
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks from 2011-03-01 00:00:00 and';
    is scalar @$ticks, 2, 'All in all 2 ticks found';

    subtest 'Authenticity Checks' => sub {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 15,
            hour   => 12,
            minute => 12,
            second => 1
        );
        is $ticks->[0]->epoch, $date->epoch, 'Correct tick ' . $date->ymd . ' ' . $date->hms;

        $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 16,
            hour   => 12,
            minute => 12,
            second => 1
        );
        is $ticks->[1]->epoch, $date->epoch, 'Correct tick ' . $date->ymd . ' ' . $date->hms;
    };
};

subtest 'Tick Fetch - Start-Limit - Beserk User' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    throws_ok {
        warnings_like { my $ticks = $api->ticks_start_limit({start_time => '2012-05-15 23:00:00'}); }
        qr/Error sanity_checks_start_limit: start time\(1337644800\) and limit(<NULL>) should be provided/;
    }
    qr/sanity_checks_start_limit/, 'No Limit - We don\'t entertain such queries 1';

    throws_ok {
        warnings_like { my $ticks = $api->ticks_start_limit({limit => 25}); }
        qr/Error sanity_checks_start_limit: start time\(<NULL>\) and limit(25) should be provided/;
    }
    qr/sanity_checks_start_limit/, 'No Start Time - We don\'t entertain such queries 2';
};

subtest 'Tick Fetch - End-Limit - Simple' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $end_time = '2012-05-20 14:00:00';
    my $ticks    = $api->ticks_end_limit({
        end_time => $end_time,
        limit    => 10
    });
    isa_ok $ticks, 'ARRAY', "Got ticks upto $end_time and";
    is scalar @$ticks, 9, 'All in all 9 ticks found';

    subtest 'Tick datatype' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            isa_ok $tick, 'Quant::Framework::Spot::Tick', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    is $ticks->[0]->epoch, Date::Utility->new($end_time)->epoch, 'first tick epochi ok';

    subtest 'Order Check - Descending' => sub {
        my $previous_tick = 9999999999;
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->epoch < $previous_tick, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_tick = $tick->epoch;
        }
    };

    subtest 'No frxUSDAUD' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->quote > 2, 'Tick at ' . $date->datetime_yyyymmdd_hhmmss . ' is frxUSDJPY';
        }
    };
};

subtest 'Tick Fetch - End-Limit - Limit 2' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ticks = $api->ticks_end_limit({
        end_time => '2012-05-20 23:00:00',
        limit    => 2
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks from 2012-05-20 23:00:00 and';
    is scalar @$ticks, 2, 'All in all 2 ticks found';

    subtest 'Authenticity Checks' => sub {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 20,
            hour  => 14
        );
        is $ticks->[0]->epoch, $date->epoch, 'Correct tick ' . $date->ymd . ' ' . $date->hms;

        $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 19,
            hour  => 12
        );
        is $ticks->[1]->epoch, $date->epoch, 'Correct tick ' . $date->ymd . ' ' . $date->hms;
    };
};

subtest 'Tick Fetch - End-Limit - Limit 2, but it can be any day' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ticks = $api->ticks_end_limit({
        end_time => '2015-01-01 00:00:00',
        limit    => 2
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks from 2015-01-01 00:00:00 and';
    is scalar @$ticks, 2, 'All in all 2 ticks found';

    subtest 'Authenticity Checks' => sub {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 20,
            hour  => 14
        );
        is $ticks->[0]->epoch, $date->epoch, 'Correct tick ' . $date->ymd . ' ' . $date->hms;

        $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 19,
            hour  => 12
        );
        is $ticks->[1]->epoch, $date->epoch, 'Correct tick ' . $date->ymd . ' ' . $date->hms;
    };
};

subtest 'Tick Fetch - End-Limit - Beserk User' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    throws_ok {
        warnings_like { my $ticks = $api->ticks_end_limit({end_time => '2012-05-15 23:00:00'}); }
        qr/Error sanity_checks_start_limit: end_t\(2012-05-15 23:00:00\) and limit\(<NULL>\) should be provided/;
    }
    qr/sanity_checks_end_limit/, 'No Limit - We don\'t entertain such queries 1';

    throws_ok {
        warnings_like { my $ticks = $api->ticks_end_limit({limit => 25}); }
        qr/ Error sanity_checks_start_limit: end_t(<NULL>) and limit(25) should be provided/;
    }
    qr/sanity_checks_end_limit/, 'No End Time - We don\'t entertain such queries 2';
};
