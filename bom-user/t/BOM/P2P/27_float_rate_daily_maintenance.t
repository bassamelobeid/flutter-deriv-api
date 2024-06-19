use strict;
use warnings;

use Test::More;
use Test::MockTime qw(set_fixed_time);
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Test::Email;
use P2P;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::User::Script::P2PDailyMaintenance;
use Test::Warn;
use Date::Utility;
use Test::Fatal;
use JSON::MaybeUTF8 qw(:v1);
use Date::Utility;

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_escrow();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
my $redis  = BOM::Config::Redis->redis_p2p_write();
my $key    = 'P2P::AD_ACTIVATION';

my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $emitted_events;
$mock_events->redefine('emit' => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

my $mock_client = Test::MockModule->new('P2P');
$mock_client->redefine(p2p_exchange_rate => {quote => 1});

set_fixed_time(Date::Utility->new('2000-01-01')->epoch);

my %campaigns = (
    float_rate_notice   => 101,
    fixed_rate_disabled => 201,
    float_rate_disabled => 301
);
$config->email_campaign_ids(encode_json_utf8(\%campaigns));

subtest 'deactivate fixed ads notice' => sub {
    my $country    = 'zw';
    my $currency   = BOM::Config::CurrencyConfig::local_currency_for_country(country => $country);
    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(client_details => {residence => $country});

    my $date = '2000-01-02';
    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    deactivate_fixed => $date,
                    fixed_ads        => 'enabled',
                    float_ads        => 'disabled'
                }}));
    $redis->hset($key, "$country:deactivate_fixed", $date);
    undef $emitted_events;
    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok !$emitted_events,                                    'no events emitted if advertiser has no ads';
    ok !$redis->hexists($key, "$country:deactivate_fixed"), 'redis key removed';

    my (undef, $advert) = BOM::Test::Helper::P2P::create_advert(
        client    => P2P->new(client => $advertiser),
        rate_type => 'fixed'
    );
    $redis->hset($key, "$country:deactivate_fixed", $date);
    undef $emitted_events;
    BOM::User::Script::P2PDailyMaintenance->new->run;

    cmp_deeply(
        $emitted_events,
        {
            trigger_cio_broadcast => [{
                    campaign_id       => $campaigns{float_rate_notice},
                    ids               => [$advertiser->binary_user_id],
                    id_ignore_missing => 1,
                    data              => {
                        deactivation_date => $date,
                        local_currency    => $currency,
                        live_chat_url     => ignore(),
                    }}
            ],
        },
        'notice event emitted'
    );

    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    deactivate_fixed => $date,
                    fixed_ads        => 'disabled',
                    float_ads        => 'disabled'
                }}));
    $redis->hset($key, $country . "$country:deactivate_fixed", $date);
    undef $emitted_events;
    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok !$emitted_events, 'no events emitted if fixed ads are already disabled';

    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    deactivate_fixed => $date,
                    fixed_ads        => 'enabled',
                    float_ads        => 'disabled'
                }}));
    $redis->hset($key, $country . "$country:deactivate_fixed", $date);
    $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    );
    undef $emitted_events;
    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok !$emitted_events, 'no events emitted when advertiser has no active ad';

    $date = '1999-12-31';
    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    deactivate_fixed => $date,
                    fixed_ads        => 'enabled',
                    float_ads        => 'disabled'
                }}));
    $redis->hset($key, "$country:deactivate_fixed", $date);
    $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 1
    );
    undef $emitted_events;
    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok !(grep { $_->{campaign_id} == $campaigns{float_rate_notice} } $emitted_events->{trigger_cio_broadcast}->@*),
        'no notice emitted when date is in the past';
};

subtest 'ad deactivation' => sub {
    my $country    = 'zw';
    my $currency   = BOM::Config::CurrencyConfig::local_currency_for_country(country => $country);
    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(client_details => {residence => $country});

    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    fixed_ads => 'disabled',
                    float_ads => 'disabled'
                }}));
    $redis->hset($key, "$country:fixed_ads", 'disabled');
    undef $emitted_events;
    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok !$emitted_events,                             'no events emitted if advertiser has no ads';
    ok !$redis->hexists($key, "$country:float_ads"), 'redis key removed';

    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    fixed_ads => 'enabled',
                    float_ads => 'disabled'
                }}));
    my (undef, $fixed_ad) = BOM::Test::Helper::P2P::create_advert(
        client           => P2P->new(client => $advertiser),
        rate_type        => 'fixed',
        min_order_amount => 1,
        max_order_amount => 2
    );
    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    fixed_ads => 'disabled',
                    float_ads => 'enabled'
                }}));
    $redis->hset($key, "$country:fixed_ads", 'disabled');
    undef $emitted_events;
    BOM::User::Script::P2PDailyMaintenance->new->run;

    cmp_deeply(
        $emitted_events,
        {
            trigger_cio_broadcast => [{
                    campaign_id       => $campaigns{fixed_rate_disabled},
                    ids               => [$advertiser->binary_user_id],
                    id_ignore_missing => 1,
                    data              => {
                        local_currency => $currency,
                        live_chat_url  => ignore(),
                    }}
            ],
            p2p_adverts_updated => [{
                    advertiser_id => $advertiser->p2p_advertiser_info->{id},
                }]
        },
        'events emitted when ad disabled'
    );

    ok !$advertiser->p2p_advert_info(id => $fixed_ad->{id})->{is_active}, 'ad was disabled';

    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    fixed_ads => 'enabled',
                    float_ads => 'enabled'
                }}));
    $advertiser->p2p_advert_update(
        id        => $fixed_ad->{id},
        is_active => 1
    );
    my (undef, $float_ad) = BOM::Test::Helper::P2P::create_advert(
        client           => P2P->new(client => $advertiser),
        rate_type        => 'float',
        min_order_amount => 2.1,
        max_order_amount => 3
    );
    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    fixed_ads => 'disabled',
                    float_ads => 'disabled'
                }}));
    $redis->hset($key, "$country:fixed_ads", 'disabled');
    $redis->hset($key, "$country:float_ads", 'disabled');
    undef $emitted_events;
    BOM::User::Script::P2PDailyMaintenance->new->run;

    cmp_deeply(
        $emitted_events,
        {
            trigger_cio_broadcast => bag({
                    campaign_id       => $campaigns{fixed_rate_disabled},
                    ids               => [$advertiser->binary_user_id],
                    id_ignore_missing => 1,
                    data              => {
                        local_currency => $currency,
                        live_chat_url  => ignore(),
                    }
                },
                {
                    campaign_id       => $campaigns{float_rate_disabled},
                    ids               => [$advertiser->binary_user_id],
                    id_ignore_missing => 1,
                    data              => {
                        local_currency => $currency,
                        live_chat_url  => ignore(),
                    }}
            ),
            p2p_adverts_updated => [{
                    advertiser_id => $advertiser->p2p_advertiser_info->{id},
                }]
        },
        'events emitted when both types disabled'
    );

    ok !($redis->hexists($key, "$country:fixed_ads") or $redis->hexists($key, "$country:float_ads")), 'redis keys removed';
    ok !$advertiser->p2p_advert_info(id => $fixed_ad->{id})->{is_active},                             'fixed ad was disabled';
    ok !$advertiser->p2p_advert_info(
        id          => $float_ad->{id},
        market_rate => 1
    )->{is_active}, 'float ad was disabled';

    $config->country_advert_config(
        encode_json_utf8({
                $country => {
                    deactivate_fixed => '1999-12-31',
                    fixed_ads        => 'enabled',
                    float_ads        => 'disabled'
                }}));
    $advertiser->p2p_advert_update(
        id        => $fixed_ad->{id},
        is_active => 1
    );

    set_fixed_time(Date::Utility->new('2000-01-02')->epoch);
    undef $emitted_events;
    BOM::User::Script::P2PDailyMaintenance->new->run;

    cmp_deeply(
        $emitted_events,
        {
            trigger_cio_broadcast => [{
                    campaign_id       => $campaigns{fixed_rate_disabled},
                    ids               => [$advertiser->binary_user_id],
                    id_ignore_missing => 1,
                    data              => {
                        local_currency => $currency,
                        live_chat_url  => ignore(),
                    }}
            ],
            p2p_adverts_updated => [{
                    advertiser_id => $advertiser->p2p_advertiser_info->{id},
                }]
        },
        'events emitted when fixed ad auto disabled'
    );

    ok !$advertiser->p2p_advert_info(id => $fixed_ad->{id})->{is_active}, 'fixed ad was disabled';
    is decode_json_utf8($config->country_advert_config)->{$country}{fixed_ads}, 'disabled', 'fixed ads disabled in app config';
};

subtest 'quants alert email' => sub {
    set_fixed_time(Date::Utility->new('2000-01-01')->epoch);

    my $ad_config = {
        id => {
            fixed_ads => 'disabled',
            float_ads => 'enabled'
        },
        ng => {
            fixed_ads => 'disabled',
            float_ads => 'enabled'
        },
        za => {
            fixed_ads => 'disabled',
            float_ads => 'enabled'

        }};

    $config->country_advert_config(encode_json_utf8($ad_config));

    my %mock_rates = (
        IDR => {
            quote  => 123,
            epoch  => time,
            source => 'feed'
        },
        NGN => {
            quote  => 123,
            epoch  => Date::Utility->new('1999-07-01')->epoch,
            source => 'manual'
        },
        ZAR => {
            quote  => 456,
            epoch  => Date::Utility->new('1999-12-20')->epoch,
            source => 'feed'
        });

    my $mock_utility = Test::MockModule->new('BOM::User::Utility');
    $mock_utility->redefine(p2p_exchange_rate => sub { $mock_rates{$_[0]} });

    mailbox_clear();
    BOM::User::Script::P2PDailyMaintenance->new->run;
    my $email = mailbox_search(subject => qr/Outdated exchange rates for P2P Float Rate countries on 2000-01-01/);
    ok $email, 'Email sent';
    like $email->{body},   qr/Nigeria/,      'outdated rate reported';
    like $email->{body},   qr/South Africa/, 'outdated rate reported';
    unlike $email->{body}, qr/No rate/,      'no rate not reported';
    unlike $email->{body}, qr/Indonesia/,    'recent rate not reported';

    $ad_config->{ng}{float_ads} = 'disabled';
    $ad_config->{za}{float_ads} = 'disabled';
    $config->country_advert_config(encode_json_utf8($ad_config));

    mailbox_clear();
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $email = mailbox_search(subject => qr/Outdated exchange rates for P2P Float Rate countries on 2000-01-01/);
    ok !$email, 'No email sent when no outdated rates';

    delete $mock_rates{IDR};

    mailbox_clear();
    $ad_config->{za}{float_ads} = 'enabled';
    $config->country_advert_config(encode_json_utf8($ad_config));
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $email = mailbox_search(subject => qr/Outdated exchange rates for P2P Float Rate countries on 2000-01-01/);

    ok $email, 'Email sent';
    unlike $email->{body}, qr/Nigeria/,      'missing rate not reported if float rates disabled';
    like $email->{body},   qr/No rate/,      'no rate reported';
    like $email->{body},   qr/Indonesia/,    'country with no rate reported';
    like $email->{body},   qr/South Africa/, 'outdated rate reported';
};

done_testing;
