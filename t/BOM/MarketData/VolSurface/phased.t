use Test::Most;
use Test::FailWarnings;
use JSON qw(decode_json);

use BOM::MarketData::Fetcher::VolSurface;
use BOM::Market::Underlying;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;

my $ul = BOM::Market::Underlying->new('RDVENUS');
my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $ul});

subtest "get_volatility" => sub {
    plan tests => 90;

    my $prev_vol = 0;
    foreach my $start_epoch (1 .. 9) {
        foreach my $end_epoch (10 .. 19) {
            my $this_vol = $volsurface->get_volatility({
                start_epoch => $start_epoch,
                end_epoch   => $end_epoch
            });
            isnt($this_vol, $prev_vol, 'Each period vol is uniquely determined.');
            $prev_vol = $this_vol;
        }
    }

};

done_testing;
