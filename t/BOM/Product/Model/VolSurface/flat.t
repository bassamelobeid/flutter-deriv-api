use Test::Most;
use Test::FailWarnings;
use JSON qw(decode_json);

use BOM::MarketData::Fetcher::VolSurface;

use BOM::Market::Underlying;
use BOM::Test::Data::Utility::UnitTestMD qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;

my $ul              = BOM::Market::Underlying->new('R_50');

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
            0.07,
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
                0.5,
                '.. with a flat vol at a strike of ' . $strike
            );
        }
    }
};

done_testing;
