use Test::Most;
use Test::FailWarnings;
use JSON qw(decode_json);

use BOM::MarketData::Fetcher::VolSurface;

use BOM::Market::Underlying;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;

my $ul              = BOM::Market::Underlying->new('R_50');
my $flat_vol        = rand(5);
my $flat_atm_spread = rand;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'RANDOM',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol          => $ul->symbol,
        flat_vol        => $flat_vol,
        flat_atm_spread => $flat_atm_spread,
        recorded_date   => Date::Utility->new,
    });

subtest "looks flat" => sub {
    plan tests => 630;

    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $ul});
    for (0 .. 29) {
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
        for (0 .. 19) {
            my $strike = rand(20000);
            is(
                $volsurface->get_volatility({
                        days   => $days,
                        strike => $strike
                    }
                ),
                $flat_vol,
                '.. with a flat vol at a strike of ' . $strike
            );
        }
    }
};

done_testing;
