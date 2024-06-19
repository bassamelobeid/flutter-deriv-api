use strict;
use warnings;
use Test::More;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
ok !$client->has_doughflow_payment, 'new client is false';

$client->account('USD');
BOM::Test::Helper::Client::top_up($client, 'USD', 1);
ok !$client->has_doughflow_payment, 'still false after non doughflow deposit';

$client->payment_doughflow(
    currency => 'USD',
    remark   => 'x',
    amount   => 1
);

ok $client->has_doughflow_payment, 'true after doughflow deposit';

done_testing();
