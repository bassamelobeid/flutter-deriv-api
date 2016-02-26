use Test::Most;
use Test::FailWarnings;
use Cwd qw( abs_path );
use File::Basename qw( dirname );
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURGBP',
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/EUR GBP/);

use lib abs_path(dirname(__FILE__));
use BloombergSurfaces;

my $bbss = BloombergSurfaces->new(relative_data_dir => 'transform_to_cutoff');

subtest 'There and back.' => sub {
    plan tests => 2;

    my $recorded_date = Date::Utility->new('2011-11-28 05:05:25');
    my $start         = $bbss->get('frxEURGBP', $recorded_date->datetime_yyyymmdd_hhmmss, 'New York 10:00');
    my $there         = $start->generate_surface_for_cutoff('Tokyo 15:00');

    isnt($start->surface->{7}->{smile}->{25}, $there->{7}->{smile}->{25}, 'Vols on different cuts are different');

    my $and_back = BOM::MarketData::VolSurface::Delta->new(
        symbol        => 'frxEURGBP',
        surface       => $there,
        cutoff        => 'Tokyo 15:00',
        recorded_date => $recorded_date,
    )->generate_surface_for_cutoff($start->cutoff);

    is_deeply($start->surface, $and_back, 'Transforming from one surface to another then back.');
};

subtest transform_to_cutoff => sub {

    # Bit of a beast, this one.
    # What happens here is that for all surfaces that package BloombergSurfaces
    # can give us, we test that when we cut the New York 10:00 ourselves, each
    # vol point on the resulting surface is within a chosen threshold (see
    # _acceptable_tolerance_for_maturity below) of Bloomberg's own cut.

    while (my ($symbol, $timestamps) = each %{$bbss->surfaces}) {
        while (my ($timestamp, $cutoffs) = each %{$timestamps}) {

            # The New York 10:00, which we will cut.
            my $ny10 = $bbss->get($symbol, $timestamp, 'New York 10:00');

            SURFACE:
            while (my ($cutoff, $lines) = each %{$cutoffs}) {

                next SURFACE if ($cutoff eq 'New York 10:00');

                # The two surface that we will compare: Bloombergs cut
                # of the New York 10:00, and our own.
                my $bb_cut = $bbss->get($symbol, $timestamp, $cutoff);
                my $our_cut = $ny10->generate_surface_for_cutoff($cutoff);

                # Delving into the actual surface now.
                while (my ($maturity, $smiles) = each %{$bb_cut->surface}) {

                    while (my ($delta, $bb_vol) = each %{$smiles->{smile}}) {

                        my $our_vol      = $our_cut->{$maturity}->{smile}->{$delta};
                        my $percent_diff = sprintf('%.2f', abs(100 * $our_vol / $bb_vol - 100));
                        my $tolerance    = _acceptable_tolerance_for_maturity($maturity, $cutoff);

                        cmp_ok($percent_diff, '<=', $tolerance, "Vol for: $symbol, $timestamp, $cutoff, $maturity, $delta");
                    }
                }
            }
        }
    }
};

# These are based purely on observed differences between our cuts and Bloomberg's.
sub _acceptable_tolerance_for_maturity {
    my ($maturity, $cutoff) = @_;

    # We have specific (and tighter) tolerances on Frankfurt and London,
    # to ensure that these cuts, which we seem to fair well on, don't
    # stray too far from BB without us noticing.
    my $tolerance_for = {
        'Tokyo 15:00' => {
            1   => 3.10,
            3   => 4.05,
            7   => 1.31,
            30  => 0.40,
            60  => 0.18,
            90  => 0.13,
            180 => 0.07,
            365 => 0.03,
        },
        'Sao Paulo 18:00' => {
            1   => 6.92,
            3   => 3.23,
            7   => 1.25,
            30  => 0.21,
            60  => 0.11,
            90  => 0.08,
            180 => 0.34,
            365 => 0.02,
        },
        'Frankfurt 14:30' => {
            1   => 0.44,
            3   => 0.57,
            7   => 0.17,
            30  => 0.03,
            60  => 0.02,
            90  => 0.02,
            180 => 0.01,
            365 => 0.01,
        },
        'Wellington 17:00' => {
            1   => 4.03,
            3   => 5.21,
            7   => 1.62,
            30  => 0.49,
            60  => 0.22,
            90  => 0.16,
            180 => 0.09,
            365 => 0.04,
        },
        'London 12:00' => {
            1   => 0.90,
            3   => 1.17,
            7   => 0.42,
            30  => 0.14,
            60  => 0.06,
            90  => 0.04,
            180 => 0.02,
            365 => 0.01,
        },
        'Warsaw 11:00' => {
            1   => 6.38,
            7   => 1.10,
            3   => 0.99,
            30  => 0.20,
            60  => 0.11,
            90  => 0.12,
            180 => 0.05,
            365 => 0.02,
        },
    };

    my $tolerance = $tolerance_for->{$cutoff}->{$maturity};

    return $tolerance || die "Unsupported maturity[$maturity] cutoff[$cutoff]";
}

subtest generate_default_transform_cut_list => sub {
    my $made_up_surface = {
        1 => {
            smile => {
                25 => 0.1,
                50 => 0.11,
                75 => 0.12
            }
        },
        7 => {
            smile => {
                25 => 0.2,
                50 => 0.21,
                75 => 0.22
            }
        },
        14 => {
            smile => {
                25 => 0.21,
                50 => 0.23,
                75 => 0.21
            }
        },
    };

    my $s = BOM::MarketData::VolSurface::Delta->new(
        surface       => $made_up_surface,
        underlying    => BOM::Market::Underlying->new('frxEURGBP'),
        recorded_date => Date::Utility->new,
    );

    is(keys %{$s->surfaces_to_save}, 3, 'generates cutoff for default list');
    ok($s->document->{surfaces}->{'New York 10:00'}, 'has master surface');
    ok($s->document->{surfaces}->{'UTC 21:00'},      'has transformed UTC 21:00 surface');
    ok($s->document->{surfaces}->{'UTC 23:59'},      'has transformed UTC 23:59 surface');

    my $new_s = BOM::MarketData::VolSurface::Delta->new(
        underlying => BOM::Market::Underlying->new('frxEURGBP'),
        cutoff     => 'Tokyo 15:00'
    );
    ok($new_s->surface,                               'can get surface for different cutoff');
    ok($new_s->document->{surfaces}->{'Tokyo 15:00'}, 'has transformed Tokyo 15:00 surface');
};

done_testing;
