use strict;
use warnings;
use Test::More;
use Test::Deep;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
use Encode;

use LandingCompany::Registry;

use await;

#we need this because of calculating max exchange rates on currency config
populate_exchange_rates();

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
    for my $country ('', qw(my xx invalid)) {
        my $t = build_wsapi_test(
            undef,
            {
                'CF-IPCOUNTRY'     => 'fr',
                'X-Client-Country' => $country,
            });
        my $res = $t->await::website_status({website_status => 1});
        is($res->{website_status}{clients_country}, 'fr', 'use CF country when Binary app header is ' . $country);
        $t->finish_ok;
    }
    for my $country (qw(id)) {
        my $t = build_wsapi_test(
            undef,
            {
                'CF-IPCOUNTRY'     => 'fr',
                'X-Client-Country' => $country,
            });
        my $res = $t->await::website_status({website_status => 1});
        is($res->{website_status}{clients_country}, $country, 'use Binary app header when country is ' . $country);
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
    cmp_deeply($res->{payout_currencies}, bag(LandingCompany::Registry->new()->all_currencies()), 'payout currencies are correct')
        or note explain $res;
    $t->finish_ok;
    done_testing;
};

done_testing();
