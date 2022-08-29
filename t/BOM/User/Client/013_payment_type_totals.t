use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;

use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->account('USD');
$client->set_db('write');

my %set_db;
my $client_mock = Test::MockModule->new(ref($client));
$client_mock->mock(
    'set_db',
    sub {
        $set_db{$_[1]}++;
        $client_mock->original('set_db')->(@_);
    });

cmp_deeply($client->payment_type_totals(), [], 'no payments yet',);

is $set_db{replica}, 1,       'replica was set';
is $set_db{write},   1,       'write was set';
is $client->get_db,  'write', 'db remains write';

$client->smart_payment(
    payment_type => 'affiliate_reward',
    currency     => $client->currency,
    remark       => 'x',
    amount       => 3,
);

$client->payment_doughflow(
    currency => $client->currency,
    remark   => 'x',
    amount   => 2,
);

$client->payment_doughflow(
    currency => $client->currency,
    remark   => 'x',
    amount   => -1,
);

$client->set_db('replica');
%set_db = ();

cmp_deeply(
    $client->payment_type_totals(),
    set({
            payment_type => 'affiliate_reward',
            withdrawals  => num(0),
            deposits     => num(3)
        },
        {
            payment_type => 'external_cashier',
            withdrawals  => num(1),
            deposits     => num(2)
        },
    ),
    'after some payments'
);

cmp_deeply \%set_db, {}, 'db not changed';
is $client->get_db, 'replica', 'db remains replica';

cmp_deeply(
    $client->payment_type_totals(payment_types => ['affiliate_reward']),
    [{
            payment_type => 'affiliate_reward',
            withdrawals  => num(0),
            deposits     => num(3)}
    ],
    'filter by payment type'
);

done_testing();
