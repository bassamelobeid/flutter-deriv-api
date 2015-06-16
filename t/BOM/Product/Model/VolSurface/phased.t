use Test::Most;
use Test::FailWarnings;
use JSON qw(decode_json);

use BOM::MarketData::Fetcher::VolSurface;
use BOM::Market::Underlying;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;

my $ul              = BOM::Market::Underlying->new('RDVENUS');
my $flat_vol        = rand(5);
my $flat_atm_spread = rand;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'RANDOM_NOCTURNE',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_phased',
    {
        symbol          => $ul->symbol,
        flat_vol        => $flat_vol,
        flat_atm_spread => $flat_atm_spread,
        recorded_date   => Date::Utility->new,
    });

my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $ul});
subtest "looks curvy" => sub {
    plan tests => 110;

    for (0 .. 9) {
        my $days = rand(365);
        is(
            $volsurface->get_spread({
                    sought_point => 'atm',
                    day          => $days
                }
            ),
            $flat_atm_spread,
            $days . ' days ATM spread is flat.'
        );
        my $prev_vol = $flat_vol;
        foreach my $fake_epoch (0 .. 9) {
            cmp_ok($volsurface->get_volatility({for_epoch => $fake_epoch}), '>=', $prev_vol, '.. with the vol moving at ' . $fake_epoch);
        }
    }
};

subtest "get_volatility_for_period" => sub {
    plan tests => 100;

    my $prev_vol = $flat_vol;
    foreach my $start_epoch (0 .. 9) {
        foreach my $end_epoch (10 .. 19) {
            my $this_vol = $volsurface->get_volatility_for_period($start_epoch, $end_epoch);
            isnt($this_vol, $prev_vol, 'Each period vol is uniquely determined.');
            $prev_vol = $this_vol;
        }
    }

};

done_testing;
