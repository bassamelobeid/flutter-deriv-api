use strict;
use warnings;
use Test::More;
use Test::Deep;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;
use Encode;

use await;

subtest 'country information is returned in website_status' => sub {
    for my $country (qw(my jp ru cr)) {
        my $t = build_wsapi_test(
            undef,
            {
                'CF-IPCOUNTRY' => $country,
            });
        my $res = $t->await::website_status({website_status => 1});
        is($res->{website_status}{clients_country}, $country, 'have correct country for ' . $country);
        $t->finish_ok;
    }
    done_testing;
};
subtest 'country code Malaysia' => sub {
    my $t = build_wsapi_test(
        undef,
        {
            'CF-IPCOUNTRY' => 'my',
        });
    my $res = $t->await::payout_currencies({payout_currencies => 1});
    cmp_deeply($res->{payout_currencies}, bag(qw(USD EUR GBP AUD BTC LTC BCH ETH)), 'payout currencies are correct') or note explain $res;
    $t->finish_ok;
    done_testing;
};
subtest 'country code Japan' => sub {
    my $t = build_wsapi_test(
        undef,
        {
            'CF-IPCOUNTRY' => 'jp',
        });
    my $res = $t->await::payout_currencies({payout_currencies => 1});
    cmp_deeply($res->{payout_currencies}, bag(qw(JPY)), 'payout currencies are correct') or note explain $res;
    $t->finish_ok;
    done_testing;
};

done_testing();
