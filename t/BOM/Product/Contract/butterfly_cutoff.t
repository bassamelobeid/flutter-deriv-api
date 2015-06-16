
=head1 NAME

001_butterfly_cutoff.t

=head1 DESCRIPTION

Tests the butterfly_markup based off of the butterfly_cutoff.

=cut

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use BOM::Market::Data::Tick;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FOREX',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/AUD EUR JPY USD/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'JPY',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        date         => Date::Utility->new,
        type         => 'implied',
        implied_from => 'USD'
    });

my $underlying       = BOM::Market::Underlying->new('frxUSDJPY');
my $bet_start        = Date::Utility->new('2012-02-01 01:00:00');
my $longterm_expiry  = Date::Utility->new($bet_start->epoch + 7 * 86400);
my $shortterm_expiry = Date::Utility->new($bet_start->epoch + 23 * 3540);
my $dm               = BOM::MarketData::Fetcher::VolSurface->new;

my $spot = 79.08;

# Strategy: Test that the butterfly_markup is correctly computed only for surfaces where the ON BF is greater than the butterfly_cutoff,
subtest 'ON 25D BF > 1.' => sub {
    plan tests => 6;

    my $surface = _sample_surface(
        25 => 0.10,
        50 => 0.10,
        75 => 0.10,
    );
    my $shortterm_bet = _sample_bet(
        date_expiry => $shortterm_expiry->epoch,
        volsurface  => $surface,
        barrier     => 'S0P',
        bet_type    => 'FLASHU',
    );
    my $longterm_bet = _sample_bet(
        date_expiry => $longterm_expiry->date,
        volsurface  => $surface,
    );

    my $ask_small_bf = $shortterm_bet->ask_probability;
    is($ask_small_bf->peek_amount('butterfly_greater_than_cutoff'),
        0, 'Test short term bet with ON 25D BF < 1: butterfly is not greater than the cutoff');
    is($ask_small_bf->peek_amount('butterfly_markup'), 0, 'Test short term bet with ON 25D BF < 1: butterfly_markup is indeed 0');

    $surface = _sample_surface(
        25 => 0.12,
        50 => 0.10,
        75 => 0.12,
    );
    $shortterm_bet = _sample_bet(
        date_expiry => $shortterm_expiry->epoch,
        volsurface  => $surface,
        barrier     => 'S0P',
        bet_type    => 'FLASHU',
    );
    $longterm_bet = _sample_bet(
        date_expiry => $longterm_expiry->date,
        volsurface  => $surface,
    );

    my $ask_large_bf = $shortterm_bet->ask_probability;
    is($ask_large_bf->peek_amount('butterfly_greater_than_cutoff'), 1,
        'Test short term bet with ON 25D BF > 1: butterfly is greater than the cutoff');
    cmp_ok($ask_large_bf->peek_amount('butterfly_markup'),
        '>', 0, 'Test short term bet with ON 25D BF > 1: butterfly_markup is indeed greater than 0');

    my $surface_original  = $shortterm_bet->volsurface;
    my $surface_copy_data = $surface_original->surface;
    my $first_tenor       = $surface_original->original_term_for_smile->[0];
    my $c25_original      = $surface_copy_data->{$first_tenor}->{smile}{25};
    my $c75_original      = $surface_copy_data->{$first_tenor}->{smile}{75};

    is($c25_original, 0.12, 'Test that original surface ON 25D is not modified');
    is($c75_original, 0.12, 'Test that original surface ON 75D is not modified');
};

sub _sample_surface {

    my %override_smile = @_;

    my $surface = BOM::MarketData::VolSurface::Delta->new(
        underlying    => $underlying,
        recorded_date => $bet_start,
        deltas        => [25, 50, 75],
        surface       => {
            ON => {
                smile      => {%override_smile},
                vol_spread => {
                    50 => 0.01,
                }
            },
            7 => {
                smile => {
                    25 => 0.110842,
                    50 => 0.115,
                    75 => 0.124642,
                },
                vol_spread => {
                    50 => 0.01,
                }
            },
        },
    );

    return $surface;
}

sub _sample_bet {
    my %overrides = @_;

    my $tick = BOM::Market::Data::Tick->new(
        quote  => $spot,
        epoch  => 1,
        symbol => $underlying->symbol,
    );

    my %bet_args = ((
            underlying   => $underlying->symbol,
            bet_type     => 'CALL',
            payout       => 100,
            currency     => 'USD',
            date_start   => $bet_start,
            barrier      => $spot + 0.005,
            current_tick => $tick,
            date_pricing => $bet_start,
        ),
        %overrides,
    );

    return produce_contract(\%bet_args);
}

done_testing;
