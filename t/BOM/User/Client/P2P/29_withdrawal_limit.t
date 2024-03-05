use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;

use Business::Config::LandingCompany;
use BOM::Config;
use P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Script::P2PDailyMaintenance;

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_escrow();

my $client = BOM::Test::Helper::Client::create_client();
BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

$client->account('USD');
BOM::Test::Helper::Client::top_up($client, $client->currency, 1000);
$client->status->set('age_verification', 'system', 'testing');

my $mock_config = Test::MockModule->new('Business::Config::LandingCompany');
$mock_config->mock(payment_limit => {withdrawal_limits => {$client->landing_company->short => {lifetime_limit => 500}}});

$client->payment_doughflow(
    currency          => 'USD',
    remark            => 'x',
    amount            => -100,
    payment_processor => 'x',
);

my $advertiser = $client->p2p_advertiser_create(name => 'bob');
is $advertiser->{withdrawal_limit}, '400.00', 'withdrawal_limit returned for advertiser_create';

is $client->p2p_advertiser_info->{withdrawal_limit},     '400.00', 'withdrawal_limit returned from advertiser_info';
is $client->p2p_advertiser_update()->{withdrawal_limit}, '400.00', 'withdrawal_limit returned from advertiser_update (no changes)';
is $client->p2p_advertiser_update(contact_info => 'y')->{withdrawal_limit}, '400.00',
    'withdrawal_limit returned from advertiser_update (actual update)';

my $ad = P2P->new(client => $client)->p2p_advert_create(
    type             => 'sell',
    amount           => 100,
    local_currency   => 'myr',
    rate             => 1,
    rate_type        => 'fixed',
    min_order_amount => 50,
    max_order_amount => 100,
    payment_method   => 'bank_transfer',
    payment_info     => 'x',
    contact_info     => 'x',
);

my $other = BOM::Test::Helper::P2PWithClient::create_advertiser;
my $list  = $other->p2p_advert_list(counterparty_type => 'buy');

cmp_deeply([map { $_->{id} } @$list], [$ad->{id}], 'ad is visible');

$client->payment_doughflow(
    currency          => 'USD',
    remark            => 'x',
    amount            => -360,
    payment_processor => 'x',
);

BOM::User::Script::P2PDailyMaintenance->new->run;
delete $client->{_p2p_advertiser_cached};
is $client->p2p_advertiser_info->{withdrawal_limit}, '40.00', 'withdrawal_limit is updated by cron';

cmp_deeply($other->p2p_advert_list(counterparty_type => 'buy'), [], 'ad is hidden');

$client->set_authentication('ID_DOCUMENT', {status => 'pass'});

delete $client->{_p2p_advertiser_cached};
is $client->p2p_advertiser_info->{withdrawal_limit}, undef, 'withdrawal_limit reset after fully auth';

done_testing();
