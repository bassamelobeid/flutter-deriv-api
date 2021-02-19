use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Format::Util::Numbers qw(formatnumber);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;
use Test::Exception;
use Test::MockModule;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::User::Client::PaymentAgent;

my $orig_pp = BOM::Config::Runtime->instance->app_config->payments->credit_card_processors;
my $orig_to = BOM::Config::Runtime->instance->app_config->payments->p2p->credit_card_turnover_requirement;

BOM::Config::Runtime->instance->app_config->payments->credit_card_processors(['apples', 'oranges']);
BOM::Config::Runtime->instance->app_config->payments->p2p->credit_card_turnover_requirement(25);

BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);
BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my $client     = BOM::Test::Helper::P2P::create_advertiser();
my $advertiser = BOM::Test::Helper::P2P::create_advertiser();

deposit($advertiser, 10, 'nuts');
deposit($client,     10, 'nuts');

lives_ok { BOM::Test::Helper::P2P::create_advert(client => $advertiser, type => 'sell') } 'create sell ad ok';
my ($advertiser2, $buy_ad) = BOM::Test::Helper::P2P::create_advert(type => 'buy');

my $order;
lives_ok { $order = (BOM::Test::Helper::P2P::create_order(client => $client, advert_id => $buy_ad->{id}, amount => 1))[1] } 'create sell order ok';
$advertiser2->p2p_order_cancel(id => $order->{id});

deposit($advertiser, 10, 'apples');

cmp_deeply(
    exception { BOM::Test::Helper::P2P::create_advert(client => $advertiser, type => 'sell', local_currency => 'aaa') },
    {error_code => 'SellProhibited'},
    'cannot create sell ad'
);

buy_contract($advertiser, 3, 1);

cmp_deeply(
    exception { BOM::Test::Helper::P2P::create_advert(client => $advertiser, type => 'sell', local_currency => 'aaa') },
    {error_code => 'SellProhibited'},
    'cannot create sell ad after buying multipler'
);

my $sell_ad;
buy_contract($advertiser, 3);
lives_ok { $sell_ad = BOM::Test::Helper::P2P::create_advert(client => $advertiser, type => 'sell', local_currency => 'aaa'); }
'can create sell ad after buying other contract';

deposit($client, 10, 'oranges');

cmp_deeply(
    exception { BOM::Test::Helper::P2P::create_order(client => $client, advert_id => $buy_ad->{id}, amount => 1) },
    {error_code => 'SellProhibited'},
    'cannot create sell order'
);

buy_contract($client, 3);
lives_ok { $order = (BOM::Test::Helper::P2P::create_order(client => $client, advert_id => $buy_ad->{id}, amount => 1))[1] }
'can create sell order after turnover met';
$advertiser2->p2p_order_cancel(id => $order->{id});

deposit($advertiser, 10, 'apples');

cmp_deeply(
    exception { BOM::Test::Helper::P2P::create_order(client => $client, advert_id => $sell_ad->{id}, amount => 1) },
    {error_code => 'OrderCreateFailAdvertiser'},
    'cannot create buy order if seller is blocked'
);

buy_contract($advertiser, 3);
lives_ok { BOM::Test::Helper::P2P::create_order(client => $client, advert_id => $sell_ad->{id}, amount => 1) }
'can create buy order if seller turnover met';

subtest 'payment agent' => sub {
    my $pa_client = BOM::Test::Helper::P2P::create_advertiser();
    deposit($pa_client, 1, 'apples');

    cmp_deeply(
        exception { BOM::Test::Helper::P2P::create_advert(client => $pa_client, type => 'sell') },
        {error_code => 'SellProhibited'},
        'non PA cannot create sell ad'
    );

    $pa_client->set_payment_agent;
    lives_ok { BOM::Test::Helper::P2P::create_advert(client => $pa_client, type => 'sell'); } 'PA can create sell ad';
};

subtest mt5 => sub {

    my $mt5_client = BOM::Test::Helper::P2P::create_advertiser();
    deposit($mt5_client, 10, 'apples');

    cmp_deeply(
        exception { BOM::Test::Helper::P2P::create_advert(client => $mt5_client, type => 'sell') },
        {error_code => 'SellProhibited'},
        'cannot create sell ad before transfer'
    );

    mt5_transfer($mt5_client, -5);
    lives_ok { BOM::Test::Helper::P2P::create_advert(client => $mt5_client, type => 'sell'); } 'Can create sell ad after transfer out';

    mt5_transfer($mt5_client, 5);
    cmp_deeply(
        exception { BOM::Test::Helper::P2P::create_advert(client => $mt5_client, type => 'sell') },
        {error_code => 'SellProhibited'},
        'cannot create sell ad after transfer in'
    );
};

subtest 'buy activity' => sub {
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
    deposit($advertiser, 10, 'apples');

    my ($buy_advertiser, $other_buy_ad) = BOM::Test::Helper::P2P::create_advert(type => 'buy');

    cmp_deeply(
        exception { BOM::Test::Helper::P2P::create_advert(client => $advertiser, type => 'sell') },
        {error_code => 'SellProhibited'},
        'cannot create sell ad firstly'
    );

    cmp_deeply(
        exception { BOM::Test::Helper::P2P::create_order(client => $advertiser, advert_id => $other_buy_ad->{id}, amount => 1) },
        {error_code => 'SellProhibited'},
        'cannot create sell order firstly'
    );

    my $ad;
    lives_ok { $ad = (BOM::Test::Helper::P2P::create_advert(client => $advertiser, type => 'buy'))[1] } 'can create buy ad';

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 3
    );
    $advertiser->p2p_order_confirm(id => $order->{id});
    $client->p2p_order_confirm(id => $order->{id});

    lives_ok { BOM::Test::Helper::P2P::create_advert(client => $advertiser, type => 'sell', local_currency => 'aaa') } 'can create sell ad now';

    lives_ok { $order = (BOM::Test::Helper::P2P::create_order(client => $advertiser, advert_id => $other_buy_ad->{id}, amount => 1))[0] }
    'can create sell order now';
    #$buy_advertiser->p2p_order_cancel(id => $order->{id});

    deposit($advertiser, 10, 'oranges');
    ($buy_advertiser, $other_buy_ad) = BOM::Test::Helper::P2P::create_advert(type => 'buy');

    cmp_deeply(
        exception { BOM::Test::Helper::P2P::create_advert(client => $advertiser, type => 'sell', local_currency => 'bbb') },
        {error_code => 'SellProhibited'},
        'cannot create sell ad after additional cc deposit'
    );

    cmp_deeply(
        exception { BOM::Test::Helper::P2P::create_order(client => $advertiser, advert_id => $other_buy_ad->{id}, amount => 1) },
        {error_code => 'SellProhibited'},
        'cannot create sell order after additional cc deposit'
    );

    my ($other_sell_advertiser, $other_sell_ad) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    ($order) = (
        BOM::Test::Helper::P2P::create_order(
            client    => $advertiser,
            advert_id => $other_sell_ad->{id},
            amount    => 3
        ))[1];
    $advertiser->p2p_order_confirm(id => $order->{id});
    $other_sell_advertiser->p2p_order_confirm(id => $order->{id});

    lives_ok { BOM::Test::Helper::P2P::create_advert(client => $advertiser, type => 'sell', local_currency => 'ccc') }
    'can create a sell ad after making buy order';
    lives_ok { BOM::Test::Helper::P2P::create_order(client => $advertiser, advert_id => $other_buy_ad->{id}, amount => 1) }
    'can create a sell order after making buy order';
};

subtest 'override' => sub {

    my $client = BOM::Test::Helper::P2P::create_advertiser();
    deposit($client, 10, 'apples');

    cmp_deeply(
        exception { BOM::Test::Helper::P2P::create_advert(client => $client, type => 'sell') },
        {error_code => 'SellProhibited'},
        'cannot create sell ad'
    );

    $client->db->dbic->dbh->do('UPDATE p2p.p2p_advertiser SET cc_sell_authorized = TRUE WHERE id = ' . $client->p2p_advertiser_info->{id});

    lives_ok { BOM::Test::Helper::P2P::create_advert(client => $client, type => 'sell') } 'can create sell ad after override';
};

done_testing();

BOM::Config::Runtime->instance->app_config->payments->credit_card_processors($orig_pp);
BOM::Config::Runtime->instance->app_config->payments->p2p->credit_card_turnover_requirement($orig_to);

sub deposit {
    my ($client, $amount, $pp) = @_;
    $client->payment_doughflow(
        amount            => $amount,
        currency          => $client->currency,
        remark            => 'test',
        payment_processor => $pp,
    );
}

sub buy_contract {
    my ($client, $price, $multiplier) = @_;
    my $now      = Date::Utility->new();
    my $duration = '15s';
    my $type     = $multiplier ? 'MULTUP' : 'CALL';

    BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $client->loginid,
                currency_code  => $client->account->currency_code,
            },
            bet_data => {
                underlying_symbol   => 'R_50',
                duration            => $duration,
                payout_price        => $price,
                buy_price           => $price,
                remark              => 'Test Remark',
                purchase_time       => $now->db_timestamp,
                start_time          => $now->db_timestamp,
                expiry_time         => $now->plus_time_interval($duration)->db_timestamp,
                settlement_time     => $now->plus_time_interval($duration)->db_timestamp,
                is_expired          => 1,
                is_sold             => 0,
                bet_class           => $multiplier ? 'multiplier' : 'higher_lower_bet',
                bet_type            => $type,
                short_code          => ($type . '_R_50_' . $price . '_' . $now->epoch . '_' . $now->plus_time_interval($duration)->epoch . '_S0P_0'),
                relative_barrier    => 'S0P',
                quantity            => 1,
                multiplier          => 10,
                basis_spot          => 1,
                stop_out_order_date => $now->db_timestamp,
                stop_out_order_amount => -1,
            },
            db => $client->db,
        })->buy_bet;

}

sub mt5_transfer {
    my $client = shift;

    $client->payment_mt5_transfer(
        amount   => shift,
        currency => $client->currency,
        staff    => 'test',
        remark   => 'test',
        fees     => 0,
        source   => 1,
    );

}
