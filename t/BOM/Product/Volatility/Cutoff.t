
=head1 NAME

01_cutoff.t

=head1 DESCRIPTION

General unit tests for BOM::MarketData::VolSurface::Cutoff.

=cut

use Test::Most;
use Test::MockTime qw( set_absolute_time restore_time );
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::MarketData::VolSurface::Cutoff;
use BOM::Market::Underlying;
use Date::Utility;

subtest 'Private method _cutoff_date_for_effective_day' => sub {
    plan tests => 5;

    my $cutoff     = BOM::MarketData::VolSurface::Cutoff->new('New York 10:00');
    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');

    is(
        $cutoff->cutoff_date_for_effective_day(Date::Utility->new('2011-11-22 02:00:00'), $underlying)->datetime_yyyymmdd_hhmmss,
        '2011-11-22 15:00:00',
        'Next NY10am cutoff date after 2011-11-21 02:00:00.'
    );

    is(
        $cutoff->cutoff_date_for_effective_day(Date::Utility->new('2011-11-22 03:00:00'), BOM::Market::Underlying->new('HSI'))
            ->datetime_yyyymmdd_hhmmss,
        '2011-11-22 15:00:00',
        'Given the HSI, next NY10am cutoff date after 2011-11-21 02:00:00.'
    );

    is(
        $cutoff->cutoff_date_for_effective_day(Date::Utility->new('2011-03-22 04:00:00'), $underlying)->datetime_yyyymmdd_hhmmss,
        '2011-03-22 14:00:00',
        'Next NY10am cutoff date after 2011-03-21 02:00:00 (in summer).'
    );

    $cutoff = BOM::MarketData::VolSurface::Cutoff->new('UTC 21:00');
    is(
        $cutoff->cutoff_date_for_effective_day(Date::Utility->new('2012-03-02 02:00:00'), $underlying)->datetime_yyyymmdd_hhmmss,
        '2012-03-02 21:00:00',
        'Friday cutoff_date for an FX pair.'
    );

    $cutoff = BOM::MarketData::VolSurface::Cutoff->new('UTC 23:59');
    is(
        $cutoff->cutoff_date_for_effective_day(Date::Utility->new('2012-04-23 00:00:00'), $underlying)->datetime_yyyymmdd_hhmmss,
        '2012-04-22 23:59:00',
        'Monday cutoff_date (falls on Sunday night GMT) for an FX pair.',
    );
};

subtest 'seconds_to_cutoff_time' => sub {
    plan tests => 7;

    my $cutoff     = BOM::MarketData::VolSurface::Cutoff->new('New York 10:00');
    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');

    throws_ok {
        $cutoff->seconds_to_cutoff_time;
    }
    qr/No "from" date given/, 'Calling seconds_to_cutoff_time without "from" date.';
    throws_ok {
        $cutoff->seconds_to_cutoff_time({from => 1});
    }
    qr/No underlying given/, 'Calling seconds_to_cutoff_time without underlying.';
    throws_ok {
        $cutoff->seconds_to_cutoff_time({
            from       => 1,
            underlying => 1
        });
    }
    qr/No maturity given/, 'Calling seconds_to_cutoff_time without maturity.';

    is(
        $cutoff->seconds_to_cutoff_time({
                from       => Date::Utility->new('2011-11-22 23:00:00'),
                maturity   => 1,
                underlying => $underlying
            }
        ),
        40 * 3600 - 2,
        '2300GMT and 10am New York cutoff.'
    );

    is(
        $cutoff->seconds_to_cutoff_time({
                from       => Date::Utility->new('2011-11-22 04:00:00'),
                maturity   => 1,
                underlying => $underlying
            }
        ),
        35 * 3600 - 1,
        '0400GMT and 10am New York cutoff.'
    );

    is(
        $cutoff->seconds_to_cutoff_time({
                from       => Date::Utility->new('2011-11-22 00:00:00'),
                maturity   => 1,
                underlying => $underlying
            }
        ),
        39 * 3600 - 1,
        '0000GMT and 10am New York cutoff (2am NY).'
    );

    $cutoff = BOM::MarketData::VolSurface::Cutoff->new('New York 10:00');
    is(
        $cutoff->seconds_to_cutoff_time({
                from       => Date::Utility->new('2011-06-14 23:00:00'),
                maturity   => 1,
                underlying => $underlying
            }
        ),
        39 * 3600 - 2,
        '2300GMT and 10am New York cutoff (summer, summer, summertime).'
    );
};

subtest code_gmt => sub {
    plan tests => 3;

    my $cutoff = BOM::MarketData::VolSurface::Cutoff->new('UTC 15:00');
    is($cutoff->code_gmt, 'UTC 15:00', 'UTC equivalent of a UTC cutoff.');

    set_absolute_time(Date::Utility->new('2012-01-05 10:00:00')->epoch);
    $cutoff = BOM::MarketData::VolSurface::Cutoff->new('New York 10:00');
    is($cutoff->code_gmt, 'UTC 15:00', 'UTC equivalent of NY1000 cutoff code in winter.');

    set_absolute_time(Date::Utility->new('2012-07-05 10:00:00')->epoch);
    $cutoff = BOM::MarketData::VolSurface::Cutoff->new('New York 10:00');
    is($cutoff->code_gmt, 'UTC 14:00', 'UTC equivalent of NY1000 cutoff code in winter.');

    restore_time();
};

subtest cutoff_date_for_effective_day => sub {
    plan tests => 1;

    my $cutoff = BOM::MarketData::VolSurface::Cutoff->new('UTC 23:59');

    my $cutoff_date = $cutoff->cutoff_date_for_effective_day(Date::Utility->new('2012-06-21'), BOM::Market::Underlying->new('frxUSDJPY'));

    is($cutoff_date->date_yyyymmdd, '2012-06-20', 'UTC 23:59 cutoff date for effective day.');
};

done_testing;
