use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Fatal;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::User::Script::P2PDailyMaintenance;
use BOM::User::Client;
use Test::Warn;
use JSON::MaybeUTF8       qw(:v1);
use POSIX                 qw(strftime);
use Format::Util::Numbers qw(formatnumber);

use constant {
    P2P_ADVERTISER_BAND_UPGRADE_PENDING   => "P2P::ADVERTISER_BAND_UPGRADE_PENDING",
    P2P_ADVERTISER_BAND_UPGRADE_COMPLETED => "P2P::ADVERTISER_BAND_UPGRADE_COMPLETED",
};

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

# populate trade band information for medium and high band
BOM::Test::Helper::P2P::populate_trade_band_db();

my @emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push @emitted_events, [@_] });

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
my $redis  = BOM::Config::Redis->redis_p2p_write();

$config->block_trade->enabled(1);
$config->block_trade->maximum_advert(20000);

subtest 'automatic upgrade for medium band' => sub {

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );
    my $advertiser_id = $advertiser->p2p_advertiser_info->{id};

    # create 3 orders which are completed normally
    for (1 .. 3) {
        my ($client, $order_create_response) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => $advert->{min_order_amount},
        );
        my $order_id = $order_create_response->{id};
        # buyer clicked I've paid
        $client->p2p_order_confirm(id => $order_id);
        # seller confirm
        $advertiser->p2p_order_confirm(id => $order_id);
    }
    # set advertiser created time > 3 months ago
    BOM::Test::Helper::P2P::set_advertiser_created_time_by_day($advertiser, -92);
    # fully authenthenticate advertiser;
    $advertiser->{client}->status->set('age_verification', 'system', 'testing');
    $advertiser->{client}->set_authentication('ID_ONLINE', {status => 'pass'});

    @emitted_events = ();
    mailbox_clear();
    cmp_deeply(
        [$advertiser->p2p_advertiser_info->@{qw(daily_buy_limit daily_sell_limit)}],
        ["100.00", "100.00"],
        'by default daily buy and sell limit belong to low band'
    );
    BOM::User::Script::P2PDailyMaintenance->new->run;

    cmp_deeply(
        \@emitted_events,
        [[
                'p2p_limit_changed',
                {
                    loginid           => $advertiser->loginid,
                    advertiser_id     => $advertiser_id,
                    new_sell_limit    => formatnumber('amount', $advertiser->currency, "2000"),
                    new_buy_limit     => formatnumber('amount', $advertiser->currency, "5000"),
                    account_currency  => $advertiser->currency,
                    change            => 1,
                    automatic_approve => 1,
                    block_trade       => 0,
                }
            ],
            [
                'p2p_advertiser_updated',
                {
                    client_loginid => $advertiser->loginid,
                    self_only      => 1
                }
            ],
        ],
        'p2p_advertiser_updated and p2p_limit_changed events emitted'
    );

    my $email = mailbox_search(subject => qr/P2P Band Upgrade list/);
    ok !$email, 'No email sent for medium band upgrade';
    is $redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_id), undef, 'redis field not populated for medium band upgrade';
    delete $advertiser->{_p2p_advertiser_cached};
    cmp_deeply(
        [$advertiser->p2p_advertiser_info->@{qw(daily_sell_limit daily_buy_limit)}],
        ["2000.00", "5000.00"],
        'daily buy and sell limit upgraded to medium band'
    );
};

subtest 'manual upgrade for high band' => sub {

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );
    my $advertiser_id = $advertiser->p2p_advertiser_info->{id};
    # create 3 orders which are completed normally
    for (1 .. 3) {
        my ($client, $order_create_response) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
        );
        my $order_id = $order_create_response->{id};
        # buyer clicked I've paid
        $client->p2p_order_confirm(id => $order_id);
        # seller confirm
        $advertiser->p2p_order_confirm(id => $order_id);
    }
    # set advertiser created time > 6 months ago
    BOM::Test::Helper::P2P::set_advertiser_created_time_by_day($advertiser, -182);
    # fully authenticate advertiser;
    $advertiser->{client}->status->set('age_verification', 'system', 'testing');
    $advertiser->{client}->set_authentication('ID_ONLINE', {status => 'pass'});

    @emitted_events = ();
    mailbox_clear();
    BOM::User::Script::P2PDailyMaintenance->new->run;
    cmp_deeply(
        \@emitted_events,
        [[
                'p2p_limit_upgrade_available',
                {
                    loginid       => $advertiser->loginid,
                    advertiser_id => $advertiser_id,
                }
            ],
            [
                'p2p_advertiser_updated',
                {
                    client_loginid => $advertiser->loginid,
                    self_only      => 1
                }
            ],
        ],
        'p2p_limit_upgrade_available and p2p_advertiser_updated events emitted'
    );
    my $upgrade_info = decode_json_utf8($redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_id));

    cmp_deeply(
        $upgrade_info,
        {
            client_loginid        => $advertiser->loginid,
            account_currency      => $advertiser->currency,
            days_since_joined     => 182,
            target_trade_band     => 'high',
            target_band_country   => 'default',
            target_max_daily_sell => '10000',
            target_max_daily_buy  => '10000',
            target_block_trade    => 0,
            completed_orders      => 3,
            completion_rate       => '1.000',
            dispute_rate          => '0.000',
            fraud_count           => 0,
            fully_authenticated   => 1,
            email_alert_required  => 1,
            old_trade_band        => 'low',
            old_band_country      => 'default',
            turnover              => num(3),
            payment_agent_tier    => undef,

        },
        "advertiser eligible for high band via manual upgrade"
    );
    cmp_deeply(
        $advertiser->p2p_advertiser_info->{upgradable_daily_limits},
        {
            max_daily_sell => '10000.00',
            max_daily_buy  => '10000.00',
            block_trade    => 0,
        },
        'advertiser next available band information returned correctly'
    );
    is $redis->hget(P2P_ADVERTISER_BAND_UPGRADE_COMPLETED, $advertiser_id), undef,
        'redis field for upgrade completion not populated for high band prior to manual upgrade';
    my $email = mailbox_search(subject => qr/P2P Band Upgrade list/);
    ok !$email, 'No email sent for high band prior to upgrade';
    cmp_deeply(
        [$advertiser->p2p_advertiser_info->@{qw(daily_sell_limit daily_buy_limit)}],
        ["100.00", "100.00"],
        'daily buy and sell limit still in low band as upgrade yet to be initiated'
    );
    @emitted_events = ();
    my $update = $advertiser->p2p_advertiser_update(upgrade_limits => 1);
    delete $advertiser->{_p2p_advertiser_cached};
    ok !exists $update->{upgradable_daily_limits}, 'limit upgrade was successful';
    is $redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_id), undef, 'redis field deleted successfully';
    my $upgrade_complete_info = decode_json_utf8($redis->hget(P2P_ADVERTISER_BAND_UPGRADE_COMPLETED, $advertiser_id));

    cmp_deeply(
        $upgrade_complete_info,
        {
            %$upgrade_info,
            country         => $advertiser->residence,
            old_trade_band  => 'low',
            old_buy_limit   => '100.00',
            old_sell_limit  => '100.00',
            upgrade_date    => num(time, 1),
            old_block_trade => 0,
        },
        "high band successful upgrade data populated correctly"
    );

    cmp_deeply(
        \@emitted_events,
        [
            ['p2p_advertiser_updated', {client_loginid => $advertiser->loginid}],
            ['p2p_adverts_updated',    {advertiser_id  => $update->{id}}],
            [
                'p2p_limit_changed',
                {
                    loginid           => $advertiser->loginid,
                    advertiser_id     => $update->{id},
                    new_sell_limit    => formatnumber('amount', $advertiser->currency, "10000"),
                    new_buy_limit     => formatnumber('amount', $advertiser->currency, "10000"),
                    account_currency  => $advertiser->currency,
                    change            => 1,
                    automatic_approve => 0,
                    block_trade       => 0,
                }
            ],
        ],
        'p2p_advertiser_updated, p2p_adverts_updated and p2p_limit_changed events emitted'
    );

    mailbox_clear();
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $email = mailbox_search(subject => qr/P2P Band Upgrade list/);
    ok $email, 'Email sent';
    like $email->{body},   qr/high/,           'high band upgrade reported';
    like $email->{body},   qr/$advertiser_id/, 'high band upgrade reported for correct advertiser';
    unlike $email->{body}, qr/medium/,         'no medium band upgrade reported';
    is $redis->exists(P2P_ADVERTISER_BAND_UPGRADE_COMPLETED), 0, 'redis key deleted successfully';
};

subtest 'block trade' => sub {

    my $advertiser    = BOM::Test::Helper::P2P::create_advertiser;
    my $advertiser_id = $advertiser->p2p_advertiser_info->{id};

    # block_trade_medium band has min_joined_days = 365
    BOM::Test::Helper::P2P::set_advertiser_created_time_by_day($advertiser, -365);

    BOM::User::Script::P2PDailyMaintenance->new->run;

    my $upgrade_info = decode_json_utf8($redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_id));

    ok $upgrade_info->{target_block_trade}, 'target_band is block_trade_medium';
    ok $upgrade_info->{target_block_trade}, 'target_block_trade set in pending upgrade info';

    $advertiser->p2p_advertiser_update(upgrade_limits => 1);
    delete $advertiser->{_p2p_advertiser_cached};

    is(
        exception {
            BOM::Test::Helper::P2P::create_advert(
                client           => $advertiser,
                block_trade      => 1,
                min_order_amount => 1000,
                max_order_amount => 5000,
                amount           => 10000,
            )
        },
        undef,
        'Can create block trade ad after upgrade'
    );
};

subtest 'turnover requirement' => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser;
    BOM::Test::Helper::P2P::set_advertiser_created_time_by_day($advertiser, -30);
    my $advertiser_id = $advertiser->p2p_advertiser_info->{id};

    $advertiser->db->dbic->dbh->do(
        "UPDATE p2p.p2p_country_trade_band SET automatic_approve = NULL;
         INSERT INTO p2p.p2p_country_trade_band (trade_band, country, currency, max_daily_buy, max_daily_sell, automatic_approve, email_alert_required, min_turnover)
           VALUES ('high_turnover', 'default', 'USD', 1000, 2000, FALSE, TRUE, 100);"
    );

    BOM::User::Script::P2PDailyMaintenance->new->run;
    delete $advertiser->{_p2p_advertiser_cached};
    is $advertiser->_p2p_advertiser_cached->{trade_band}, 'low', 'band not changed';
    ok !$redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_id), 'no upgrade yet';

    my ($seller, $ad) = BOM::Test::Helper::P2P::create_advert(
        type             => 'sell',
        max_order_amount => 100
    );
    my (undef, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $advertiser,
        advert_id => $ad->{id},
        amount    => 100
    );
    $advertiser->p2p_order_confirm(id => $order->{id});
    $seller->p2p_order_confirm(id => $order->{id});

    BOM::User::Script::P2PDailyMaintenance->new->run;
    delete $advertiser->{_p2p_advertiser_cached};
    is $advertiser->_p2p_advertiser_cached->{trade_band}, 'low', 'band still not changed';

    my $upgrade_info = decode_json_utf8($redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_id));
    is $upgrade_info->{target_trade_band}, 'high_turnover', 'upgrade available';
    cmp_ok $upgrade_info->{turnover}, '==', 100, 'turnover stored in redis pending key';

    $advertiser->p2p_advertiser_update(upgrade_limits => 1);
    delete $advertiser->{_p2p_advertiser_cached};
    is $advertiser->_p2p_advertiser_cached->{trade_band}, 'high_turnover', 'band changed after upgrade';

    my $upgrade_complete_info = decode_json_utf8($redis->hget(P2P_ADVERTISER_BAND_UPGRADE_COMPLETED, $advertiser_id));
    is $upgrade_complete_info->{target_trade_band}, 'high_turnover', 'new band stored in redis key';
    cmp_ok $upgrade_complete_info->{turnover}, '==', 100, 'turnover stored in redis completed key';
};

subtest 'payment agent requirement' => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser;

    $advertiser->{client}->status->set('age_verification', 'system', 'testing');    # needed to keep is_approved when pa tier changes
    BOM::Test::Helper::P2P::set_advertiser_created_time_by_day($advertiser, -30);
    my $advertiser_id = $advertiser->p2p_advertiser_info->{id};

    $advertiser->db->dbic->dbh->do(
        "UPDATE p2p.p2p_country_trade_band SET automatic_approve = NULL;
         INSERT INTO p2p.p2p_country_trade_band (trade_band, country, currency, max_daily_buy, max_daily_sell, automatic_approve, email_alert_required, payment_agent_tier)
           VALUES ('payment_agent', 'default', 'USD', 1000, 2000, TRUE, FALSE, 'premium');"
    );

    $advertiser->{client}->payment_agent({
        payment_agent_name    => 'x',
        email                 => $advertiser->{client}->email,
        information           => 'x',
        summary               => 'x',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'applied',
        currency_code         => 'USD',
        is_listed             => 't',
    });

    my $tier_id = $advertiser->db->dbic->dbh->selectrow_array('SELECT id FROM betonmarkets.pa_tier_create(?,?,?,?,?)', undef, 'premium', 0, 1, 0, 0);
   
    $advertiser->{client}->payment_agent->tier_id($tier_id);
    $advertiser->{client}->save;

    BOM::User::Script::P2PDailyMaintenance->new->run;
    delete $advertiser->{_p2p_advertiser_cached};
    is $advertiser->_p2p_advertiser_cached->{trade_band}, 'low', 'band not changed for applied PA';
    ok !$redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_id), 'no upgrade available';

    $advertiser->{client}->payment_agent->status('authorized');
    $advertiser->{client}->save;

    BOM::User::Script::P2PDailyMaintenance->new->run;
    delete $advertiser->{_p2p_advertiser_cached};
    is $advertiser->_p2p_advertiser_cached->{trade_band}, 'payment_agent', 'band changed after PA is authorized';
    ok !$redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_id), 'no upgrade available';
};

done_testing;
