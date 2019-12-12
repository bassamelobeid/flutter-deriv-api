use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More;

use BOM::User::Client;
use ClientAccountTestHelper;

my %mapping = (
    RU => 'RUB',
    MY => 'MYR',
    ID => 'IDR',
    NG => 'NGN',
    BR => 'BRL',
);

for my $country (sort keys %mapping) {
    my $client = ClientAccountTestHelper::create_client({
        broker_code => 'CR',
        email       => 'test' . rand . '@binary.com',
        residence   => $country,
    });
    is($client->local_currency, $mapping{$country}, 'currency mapping for ' . $country);
}

done_testing;

