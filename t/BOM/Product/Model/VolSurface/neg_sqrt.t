use strict;
use warnings;

use 5.010;
use Test::Most;

$ENV{QUANT_FRAMEWORK_VOLSURFACE_NOCACHE} = 1;
use List::Util qw( max );
use Test::MockObject::Extends;
use Test::Warn;
use Test::FailWarnings -allow_deps => 1;
use Scalar::Util qw( looks_like_number );
use Test::MockModule;
use File::Spec;
use Postgres::FeedDB::Spot::Tick;

use Format::Util::Numbers qw(roundcommon);
use Date::Utility;
use Quant::Framework::Utils::Test;
use Quant::Framework::VolSurface::Delta;

use Number::Closest::XS qw(find_closest_numbers_around);

my ($chronicle_r, $chronicle_w) = Data::Chronicle::Mock::get_mocked_chronicle();

my $date = Date::Utility->new('2019-02-18');

Quant::Framework::Utils::Test::create_doc(
    'currency',
    {
        symbol           => $_,
        recorded_date    => $date,
        chronicle_reader => $chronicle_r,
        chronicle_writer => $chronicle_w,
    }) for (qw/EUR JPY USD JPY-USD EUR-USD USD-EUR/);

Quant::Framework::Utils::Test::create_doc(
    'holiday',
    {
        recorded_date => $date,
        calendar      => {
            "18-Feb-2019" => {
                "Dummy Christmas Day" => [qw(LSE FOREX METAL)],
            },
        },
        chronicle_reader => $chronicle_r,
        chronicle_writer => $chronicle_w,
    });

Quant::Framework::Utils::Test::create_doc(
    'partial_trading',
    {
        recorded_date => $date,
        type          => 'early_closes',
        calendar      => {
            '14-Feb-2019' => {
                '18h' => ['FOREX', 'METAL'],
            },
        },
        chronicle_reader => $chronicle_r,
        chronicle_writer => $chronicle_w,
    });

Quant::Framework::Utils::Test::create_doc(
    'economic_events',
    {
        recorded_date    => $date,
        chronicle_reader => $chronicle_r,
        chronicle_writer => $chronicle_w,
    });

# The surface used in this test is based on shortcode PUT_FRXAUDUSD_1.93_1550494642_1550527200F_S0P_0 priced at 2019-02-18 21:48:00

subtest 'no negative square root error' => sub {

    my $surface = _get_surface();

    my $from = Date::Utility->new('2019-02-18 17:52:04');
    my $to   = Date::Utility->new('2019-02-18 23:59:59');

    my $number_of_days = ($to->epoch - $from->epoch) / 86400;
    is $number_of_days, 0.255497685185185, 'Correct number of days';

    my $smile = $surface->get_smile($from, $to);
    is $smile->{25}, 0.0600873459163785, 'Smile for delta 25 is correct.';
    is $smile->{50}, 0.060705607996547,  'Smile for delta 50 is correct.';
    is $smile->{75}, 0.0634877873573053, 'Smile for delta 75 is correct.';

};

subtest 'same smile - forced negative variance' => sub {
    no strict 'refs';
    no warnings 'redefine';
    local *{"Quant::Framework::VolSurface::Delta::_get_variance_for_period"} = sub {
        +{
            25 => 0.000816221496371159,
            50 => -0.000833104752070541,
            75 => 0.000911218164476226,
        };

    };
    my $surface = _get_surface();

    my $from = Date::Utility->new('2019-02-18 17:52:04');
    my $to   = Date::Utility->new('2019-02-18 23:59:59');

    my $number_of_days = ($to->epoch - $from->epoch) / 86400;
    is $number_of_days, 0.255497685185185, 'Correct number of days';

    my $smile;
    warning_like { $smile = $surface->get_smile($from, $to) } qr/Got negative variance/, 'Does not die with negative sqrt error';
    eq_or_diff($smile, +{}, 'Returned smile is devoid of points');
    my $vol;
    warning_like { $vol = $surface->get_volatility({from => $from, to => $to, delta => 50}) } qr/Got negative variance/,
        "can get_volatility regardless";
    is($vol, 0.01, 'Returned vol is the VOLATILITY_ON_ERROR');
    like($surface->validation_error, qr/Got negative variance/, 'volsurface validation error is set.');
};

subtest 'economic event with non 5-minute interval starting date' => sub {

    my $event = {
        symbol       => 'USD',
        event_name   => 'Non-Farm Employment Change',
        release_date => Date::Utility->new('2019-02-18 18:01:00')->epoch
    };

    my $surface = _get_surface({}, $event);

    my $from = Date::Utility->new('2019-02-18 18:02:00');
    my $to   = Date::Utility->new('2019-02-18 19:00:00');

    my $vol = $surface->get_volatility({
        from  => $from,
        to    => $to,
        delta => 50
    });

    is $surface->validation_error, '', 'Negative variances should not occur';

};

sub _get_surface {
    my $override = shift || {};
    my $event    = shift || 0;

    my %override = %$override;
    my $ul       = Quant::Framework::Utils::Test::create_underlying(
        'frxAUDUSD',
        {
            for_date              => Date::Utility->new('2019-02-18 17:52:04'),
            default_interest_rate => 0.5,
            default_dividend_rate => 0.5,
        });

    my $surface = Quant::Framework::VolSurface::Delta->new(
        underlying       => $ul,
        creation_date    => Date::Utility->new('2019-02-18 17:45:55'),
        chronicle_reader => $chronicle_r,
        chronicle_writer => $chronicle_w,
        for_date         => Date::Utility->new('2016-02-18 17:52:04'),
        $event ? (custom_event => $event) : (),
        surface => {
            '14' => {
                'vol_spread' => {
                    '25' => '0.00999999999999999',
                    '50' => '0.00699999999999999',
                    '75' => '0.00999999999999999'
                },
                'smile' => {
                    '75' => '0.0825',
                    '50' => '0.07875',
                    '25' => '0.0778'
                },
                'tenor' => '2W'
            },
            '365' => {
                'smile' => {
                    '25' => '0.089825',
                    '50' => '0.0931',
                    '75' => '0.103875'
                },
                'tenor'      => '1Y',
                'vol_spread' => {
                    '25' => '0.0042857142857143',
                    '75' => '0.0042857142857143',
                    '50' => '0.00300000000000001'
                }
            },
            '87' => {
                'smile' => {
                    '50' => '0.08585',
                    '75' => '0.0922875',
                    '25' => '0.0835125'
                },
                'tenor'      => '3M',
                'vol_spread' => {
                    '50' => '0.00380000000000001',
                    '75' => '0.00542857142857144',
                    '25' => '0.00542857142857144'
                }
            },
            '21' => {
                'tenor' => '3W',
                'smile' => {
                    '25' => '0.0806375',
                    '75' => '0.0859625',
                    '50' => '0.081875'
                },
                'vol_spread' => {
                    '25' => '0.00707142857142859',
                    '50' => '0.00495000000000001',
                    '75' => '0.00707142857142859'
                }
            },
            '7' => {
                'vol_spread' => {
                    '50' => '0.00949999999999999',
                    '75' => '0.0135714285714286',
                    '25' => '0.0135714285714286'
                },
                'smile' => {
                    '25' => '0.0767125',
                    '75' => '0.0811375',
                    '50' => '0.0777'
                },
                'tenor' => '1W'
            },
            '58' => {
                'tenor' => '2M',
                'smile' => {
                    '25' => '0.0821375',
                    '50' => '0.084025',
                    '75' => '0.0894125'
                },
                'vol_spread' => {
                    '50' => '0.00365',
                    '75' => '0.00521428571428572',
                    '25' => '0.00521428571428572'
                }
            },
            '28' => {
                'vol_spread' => {
                    '25' => '0.00492857142857143',
                    '75' => '0.00492857142857143',
                    '50' => '0.00345'
                },
                'tenor' => '1M',
                'smile' => {
                    '50' => '0.081225',
                    '75' => '0.0857625',
                    '25' => '0.0797375'
                }
            },
            '273' => {
                'tenor' => '9M',
                'smile' => {
                    '50' => '0.09205',
                    '75' => '0.1017875',
                    '25' => '0.0890125'
                },
                'vol_spread' => {
                    '50' => '0.0032',
                    '75' => '0.00457142857142858',
                    '25' => '0.00457142857142858'
                }
            },
            '179' => {
                'smile' => {
                    '25' => '0.0868',
                    '50' => '0.089875',
                    '75' => '0.0985'
                },
                'tenor'      => '6M',
                'vol_spread' => {
                    '25' => '0.00492857142857144',
                    '50' => '0.00345000000000001',
                    '75' => '0.00492857142857144'
                }
            },
            '1' => {
                'vol_spread' => {
                    '25' => '0.0428571428571429',
                    '75' => '0.0428571428571429',
                    '50' => '0.03'
                },
                'tenor' => 'ON',
                'smile' => {
                    '25' => '0.07775',
                    '75' => '0.08215',
                    '50' => '0.07855'
                }
            },
        },
        %override,
    );

    # we don't want to use previously generated cache if it exists, we want to calculate everything from scratch
    $surface->cache->purge_cache();

    return $surface;
}

done_testing;
