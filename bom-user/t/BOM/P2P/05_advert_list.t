use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;

use BOM::User::Client;
use BOM::Test::Helper::P2PWithClient;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::ExchangeRates           qw(populate_exchange_rates);
use P2P;

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_escrow();
populate_exchange_rates();

subtest 'Seller lists ads and those with a min order amount greater than its balance are excluded' => sub {
    my $seller_balance = 10;
    my $escrow         = BOM::Test::Helper::P2PWithClient::create_escrow();
    my $seller         = BOM::Test::Helper::P2PWithClient::create_advertiser(balance => $seller_balance);

    cmp_ok $seller->account->balance, '==', $seller_balance, "Seller balance is $seller_balance";

    # this ad should be available for our buyer
    my (undef, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        type             => 'buy',
        amount           => $seller_balance * 0.5,
        max_order_amount => $seller_balance * 0.5,
        min_order_amount => $seller_balance * 0.1
    );

    # this ad should NOT be available for our buyer
    BOM::Test::Helper::P2P::create_advert(
        type             => 'buy',
        amount           => $seller_balance * 1.5,
        max_order_amount => $seller_balance * 1.5,
        min_order_amount => $seller_balance * 1.1
    );

    is scalar($seller->p2p_advert_list(use_client_limits => 1)->@*), 1, 'List correct amount of ads (1) with use_client_limits=1';
    cmp_ok $seller->p2p_advert_list(use_client_limits => 1)->[0]->{id}, '==', $advert_info->{id}, 'List ad is the expected one';

    is scalar($seller->p2p_advert_list()->@*), 2, 'list correct amount of ads (2) without use_client_limits';
};

my ($advertiser1, $advert1) = BOM::Test::Helper::P2P::create_advert(amount => 100);
my ($advertiser2, $advert2) = BOM::Test::Helper::P2P::create_advert(amount => 100);

my $client1 = BOM::Test::Helper::Client::create_client();
$client1->account('USD');
$client1->residence('id');
my $client2 = BOM::Test::Helper::Client::create_client();
$client2->account('USD');
$client2->residence('ng');
my $client3 = BOM::Test::Helper::Client::create_client();
$client3->account('EUR');

subtest 'advertiser adverts' => sub {
    cmp_deeply(
        exception {
            $client1->p2p_advertiser_adverts()
        },
        {error_code => 'AdvertiserNotRegistered'},
        "non advertiser gets error"
    );

    $advertiser2->p2p_advertiser_update(is_listed => 0);

    is $advertiser1->p2p_advertiser_adverts()->[0]{id}, $advert1->{id}, 'advertiser 1 (active) gets advert';
    is $advertiser1->p2p_advertiser_adverts()->@*,      1,              'advertiser 1 got one';
    is $advertiser2->p2p_advertiser_adverts()->[0]{id}, $advert2->{id}, 'advertiser 2 (inactive) gets advert';
    is $advertiser2->p2p_advertiser_adverts()->@*,      1,              'advertiser 2 got one';
};

subtest 'country & currency filtering' => sub {
    is $client1->p2p_advert_list()->@*, 3, 'Client from same country sees ad';
    is $client2->p2p_advert_list()->@*, 0, 'Client from other country does not see ads';
    is $client3->p2p_advert_list()->@*, 0, 'Client with other currency does not see ads';
};

subtest 'show real name' => sub {

    my $names = {
        first_name => 'john',
        last_name  => 'smith'
    };

    my ($advertiser, $ad) = BOM::Test::Helper::P2P::create_advert(advertiser => {%$names});
    is $ad->{advertiser_details}{first_name}, undef, 'create ad: no first name yet';
    is $ad->{advertiser_details}{last_name},  undef, 'create ad: no last name yet';

    my $res = $client1->p2p_advert_list(id => $ad->{id})->[0]->{advertiser_details};
    is $res->{first_name}, undef, 'ad list: no first name yet';
    is $res->{last_name},  undef, 'ad list: no last name yet';

    $res = $client1->p2p_advert_info(id => $ad->{id})->{advertiser_details};
    is $res->{first_name}, undef, 'ad info: no first name yet';
    is $res->{last_name},  undef, 'ad info: no last name yet';

    $res = $advertiser->p2p_advert_update(
        id        => $ad->{id},
        is_active => 0
    )->{advertiser_details};
    is $res->{first_name}, undef, 'ad update: no first name yet';
    is $res->{last_name},  undef, 'ad update: no last name yet';

    $advertiser->p2p_advertiser_update(show_name => 1);

    ($advertiser, $ad) = BOM::Test::Helper::P2P::create_advert(
        local_currency => 'xxx',
        client         => P2P->new(client => $advertiser->client),
    );

    cmp_deeply($ad->{advertiser_details}, superhashof($names), 'create ad: real names returned');

    $res = $client1->p2p_advert_list(id => $ad->{id})->[0]->{advertiser_details};
    cmp_deeply($res, superhashof($names), 'ad list: real names returned');

    $res = $client1->p2p_advert_info(id => $ad->{id})->{advertiser_details};
    cmp_deeply($res, superhashof($names), 'ad info: real names returned');

    $res = $advertiser->p2p_advert_update(
        id        => $ad->{id},
        is_active => 0
    )->{advertiser_details};
    cmp_deeply($res, superhashof($names), 'ad update: real names returned');

};

subtest 'search by advertiser name' => sub {
    my $advertiser1 = BOM::Test::Helper::P2PWithClient::create_advertiser(name => 'c%ol_guy$!_');
    my $ad          = BOM::Test::Helper::P2P::create_advert(
        client => P2P->new(client => $advertiser1),
        type   => 'buy'
    );

    my $advertiser2 = BOM::Test::Helper::P2PWithClient::create_advertiser(name => 'bob');
    BOM::Test::Helper::P2P::create_advert(
        client => P2P->new(client => $advertiser2),
        type   => 'buy'
    );

    is $advertiser2->p2p_advert_list(
        advertiser_name => 'c%ol_guy$!_',
        type            => 'buy'
    )->[0]{id}, $ad->{id}, 'full match';
    is $advertiser2->p2p_advert_list(
        advertiser_name => 'c%ol',
        type            => 'buy'
    )->[0]{id}, $ad->{id}, 'partial match';
    is $advertiser2->p2p_advert_list(
        advertiser_name => 'l_g',
        type            => 'buy'
    )->[0]{id}, $ad->{id}, 'partial match';
    is $advertiser2->p2p_advert_list(
        advertiser_name => '%',
        type            => 'buy'
    )->[0]{id}, $ad->{id}, 'partial match';
    cmp_deeply $advertiser2->p2p_advert_list(
        advertiser_name => 'g_y',
        type            => 'buy'
        ),
        [], 'no match';
    cmp_deeply $advertiser2->p2p_advert_list(
        advertiser_name => '___',
        type            => 'buy'
        ),
        [], 'no match';
    cmp_deeply $advertiser2->p2p_advert_list(
        advertiser_name => 'b_b',
        type            => 'buy'
        ),
        [], 'no match';
};

subtest 'list adverts for specific advertiser regardless of currency' => sub {
    my %advert_params = (
        account_currency  => 'USD',
        amount            => 100,
        description       => 'test advert',
        max_order_amount  => 10,
        min_order_amount  => 0.1,
        payment_method    => 'bank_transfer',
        payment_info      => 'ad pay info',
        contact_info      => 'ad contact info',
        rate              => 1.23,
        rate_type         => 'fixed',
        type              => 'buy',
        counterparty_type => 'sell',
        block_trade       => 0,
    );

    my $client_za = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'za'
    });
    $client_za->account('USD');
    $client_za->status->set('age_verification', 'system', 'testing');
    $client_za->set_authentication('ID_ONLINE', {status => 'pass'});
    my $adv_za = $client_za->p2p_advertiser_create(name => 'jafar');
    my $ad_zar = P2P->new(client => $client_za)->p2p_advert_create(%advert_params);

    my $client_india = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'in'
    });
    $client_india->account('USD');
    $client_india->status->set('age_verification', 'system', 'testing');
    $client_india->set_authentication('ID_ONLINE', {status => 'pass'});
    my $adv_india = $client_india->p2p_advertiser_create(name => 'gholi');
    my $ad_inr    = P2P->new(client => $client_india)->p2p_advert_create(%advert_params);

    cmp_deeply([map { $_->{id} } $client_za->p2p_advert_list()->@*],    [$adv_za->{id}],    "default advert list is showing only ZAR adverts");
    cmp_deeply([map { $_->{id} } $client_india->p2p_advert_list()->@*], [$adv_india->{id}], "default advert list is showing only INR adverts");

    cmp_deeply([map { $_->{id} } $client_india->p2p_advert_list(advertiser_id => $adv_za->{id})->@*],
        [$ad_zar->{id}], "search by advertiser id is showing only target advertiser adverts");
    cmp_deeply([map { $_->{id} } $client_za->p2p_advert_list(advertiser_id => $adv_india->{id})->@*],
        [$ad_inr->{id}], "search by advertiser id is showing only target advertiser adverts");
    cmp_deeply([map { $_->{id} } $client_india->p2p_advert_list(advertiser_name => $adv_za->{name})->@*],
        [$ad_zar->{id}], "search by advertiser name is showing only target advertiser adverts");

};

BOM::Test::Helper::P2PWithClient::reset_escrow();

done_testing();
