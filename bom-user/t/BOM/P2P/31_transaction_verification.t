use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use Test::Exception;
use Test::Deep;
use Test::MockTime qw(set_fixed_time);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Database::Model::OAuth;
use BOM::Platform::Token;
use BOM::Platform::Context::Request;

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_escrow();

my $emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(emit => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

my $frontend_urls;
my $mock_brand = Test::MockModule->new('Brands');
$mock_brand->mock(frontend_url => sub { push $frontend_urls->{$_[1]}->@*, @_[2 .. 3]; 'dummy' });

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
my $redis  = BOM::Config::Redis->redis_p2p_write;
$redis->del('P2P::ORDER::VERIFICATION_PENDING');

my $app_user = BOM::User->create(
    email    => 'p2p@test.com',
    password => 'x',
);

my $verification_uri = 'http://p2p_test/verify';

my $app_id = BOM::Database::Model::OAuth->new->create_app({
        user_id          => $app_user->id,
        name             => 'p2p_test',
        verification_uri => $verification_uri,
    })->{app_id};

subtest 'disabled for all countries' => sub {
    $config->transaction_verification_countries([]);
    $config->transaction_verification_countries_all(0);
    check_verification('za', 0);
};

subtest 'enabled for some countries' => sub {
    $config->transaction_verification_countries(['za', 'ng']);
    check_verification('za', 1);
    check_verification('id', 0);
};

subtest 'enabled for all countries except some' => sub {
    $config->transaction_verification_countries_all(1);
    check_verification('za', 0);
    check_verification('id', 1);
};

$config->transaction_verification_countries([]);

subtest 'successful verification' => sub {

    # needs to be done before creating client object
    BOM::Platform::Context::request(
        BOM::Platform::Context::Request->new({
                language => 'ES',
                app_id   => $app_id
            }));

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2PWithClient::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );

    $client->p2p_order_confirm(id => $order->{id});

    undef $emitted_events;
    undef $frontend_urls;

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, source => $app_id) },
        {error_code => 'OrderEmailVerificationRequired'},
        'confirmation needed'
    );

    ok my $code = $emitted_events->{p2p_order_confirm_verify}[0]{code}, 'event contains code';

    cmp_deeply(
        $emitted_events,
        {
            p2p_order_confirm_verify => [{
                    loginid            => $advertiser->loginid,
                    code               => re('\w{6}'),
                    order_id           => $order->{id},
                    order_amount       => $order->{amount},
                    order_currency     => $advertiser->currency,
                    buyer_name         => $order->{client_details}->{name},
                    verification_url   => "$verification_uri/p2p?action=p2p_order_confirm&order_id=$order->{id}&code=$code&lang=ES",
                    live_chat_url      => 'dummy',
                    password_reset_url => 'dummy',
                }
            ],
            p2p_order_updated => [{
                    client_loginid => $advertiser->loginid,
                    order_id       => $order->{id},
                }]
        },
        'p2p_order_confirm_verify event emitted',
    );

    my $info = $client->p2p_order_info(id => $order->{id});
    is $info->{verification_pending}, 1, 'client order info verification pending is 1';
    ok !exists $info->{verification_next_request}, 'client does not see verification_next_request';
    ok !exists $info->{verification_token_expiry}, 'client does not see verification_token_expiry';

    $info = $advertiser->p2p_order_info(id => $order->{id});
    is $info->{verification_pending}, 1, 'advertiser order info verification pending is 1';
    cmp_ok $info->{verification_next_request}, '<=', time + 60,        'advertiser sees verification_next_request';
    cmp_ok $info->{verification_token_expiry}, '<=', time + (60 * 10), 'advertiser sees verification_token_expiry';

    cmp_deeply(
        $frontend_urls,
        {
            live_chat => [
                $app_id,
                {
                    app_id   => $app_id,
                    language => 'ES'
                }
            ],
            lost_password => [
                $app_id,
                {
                    source   => $app_id,
                    language => 'ES'
                }
            ],
        },
        'expected front end url requests'
    );

    is $client->p2p_order_info(id => $order->{id})->{verification_pending}, 1, 'order info verification pending is 1';

    cmp_deeply(
        $advertiser->p2p_order_confirm(
            id                => $order->{id},
            verification_code => $code,
            dry_run           => 1
        ),
        {
            id      => $order->{id},
            dry_run => 1
        },
        'dry run ok'
    );

    ok $redis->exists('P2P::ORDER::VERIFICATION_HISTORY::' . $order->{id}), 'history key exists';
    ok $redis->exists('P2P::ORDER::VERIFICATION_ATTEMPT::' . $order->{id}), 'attempts key exists';

    cmp_deeply(
        $advertiser->p2p_order_confirm(
            id                => $order->{id},
            verification_code => $code
        ),
        {
            id     => $order->{id},
            status => 'completed'
        },
        'confirm ok'
    );

    ok !BOM::Platform::Token->new({token => $code})->token,                  'token was deleted';
    ok !$redis->exists('P2P::ORDER::VERIFICATION_HISTORY::' . $order->{id}), 'histroy key was deleted';
    ok !$redis->exists('P2P::ORDER::VERIFICATION_ATTEMPT::' . $order->{id}), 'attempts key was deleted';

    $info = $client->p2p_order_info(id => $order->{id});
    ok !exists $info->{verification_pending},      'client order info verification is not present after order completed';
    ok !exists $info->{verification_next_request}, 'client does not see verification_next_request';
    ok !exists $info->{verification_token_expiry}, 'client does not see verification_token_expiry';

    $info = $advertiser->p2p_order_info(id => $order->{id});
    ok !exists $info->{verification_pending},      'advertiser order info verification pending is now 0';
    ok !exists $info->{verification_next_request}, 'advertiser does not see verification_next_request';
    ok !exists $info->{verification_token_expiry}, 'advertiser does not see verification_token_expiry';
};

subtest 'bad verification codes' => sub {

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2PWithClient::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );

    $client->p2p_order_confirm(id => $order->{id});

    undef $emitted_events;

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, source => $app_id) },
        {error_code => 'OrderEmailVerificationRequired'},
        'confirmation needed'
    );

    my $good_code = $emitted_events->{p2p_order_confirm_verify}[0]{code};

    my $bad_code = BOM::Platform::Token->new({
            email       => $advertiser->email,
            created_for => 'payment_withdraw',
        })->token;

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => $bad_code, source => $app_id) },
        {error_code => 'InvalidVerificationToken'},
        'cannot use token created for other purpose'
    );

    my $err = exception { $advertiser->p2p_order_confirm(id => $order->{id}, source => $app_id) };
    is $err->{error_code}, 'ExcessiveVerificationRequests', 'error code for retry within 1 min';
    cmp_ok 60 - $err->{message_params}->[0], '<=', 1, 'message param for retry within 1 min';    # allow for 1 sec delay

    $redis->zrem('P2P::ORDER::VERIFICATION_EVENT', 'REQUEST_BLOCK|' . $order->{id} . '|' . $advertiser->loginid);

    $bad_code = BOM::Platform::Token->new({
            email       => $client->email,
            created_for => 'p2p_order_confirm',
        })->token;

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => $bad_code, source => $app_id) },
        {error_code => 'InvalidVerificationToken'},
        'cannot use token created for other client'
    );

    $redis->zrem('P2P::ORDER::VERIFICATION_EVENT', 'REQUEST_BLOCK|' . $order->{id} . '|' . $advertiser->loginid);

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => rand(), source => $app_id) },
        {error_code => 'InvalidVerificationToken'},
        'cannot use random code'
    );

    undef $emitted_events;

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => $good_code, source => $app_id) },
        {
            error_code     => 'ExcessiveVerificationFailures',
            message_params => [30],
        },
        'blocked after 3 failures'
    );

    cmp_deeply(
        $emitted_events,
        {
            p2p_order_updated => [{
                    client_loginid => $advertiser->loginid,
                    order_id       => $order->{id},
                }]
        },
        'p2p_order_updated event emitted when blocked'
    );

    my $info = $advertiser->p2p_order_info(id => $order->{id});
    cmp_ok $info->{verification_lockout_until}, '<=', time + (60 * 30), 'advertiser sees lockout until';
    ok !exists $info->{verification_next_request}, 'verification_next_request is not present after block';
    ok !exists $info->{verification_token_expiry}, 'verification_token_expiry is not present after block';
    is $info->{verification_pending}, 0, 'verification_pending is 0 after block';

    $redis->zrem('P2P::ORDER::VERIFICATION_EVENT', 'LOCKOUT|' . $order->{id} . '|' . $advertiser->loginid);

    lives_ok { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => $good_code) } 'can confirm after block removed';
};

subtest 'token timeout blocking' => sub {
    set_fixed_time(0);

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2PWithClient::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );

    $client->p2p_order_confirm(id => $order->{id});

    for (1 .. 4) {

        cmp_deeply(
            exception { $advertiser->p2p_order_confirm(id => $order->{id}) },
            {error_code => 'OrderEmailVerificationRequired'},
            "confirmation needed for try $_"
        );

        $redis->zrem('P2P::ORDER::VERIFICATION_EVENT', 'REQUEST_BLOCK|' . $order->{id} . '|' . $advertiser->loginid);
        set_fixed_time(time + 60);
    }

    set_fixed_time(719);    # 11:59

    undef $emitted_events;

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}) },
        {error_code => 'OrderEmailVerificationRequired'},
        'still not blocked at 11:59 min, because only 2 tokens expired'
    );

    my $code = $emitted_events->{p2p_order_confirm_verify}[0]{code};

    set_fixed_time(720);    # 12:00

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => $code) },
        {
            error_code     => 'ExcessiveVerificationFailures',
            message_params => [30],
        },
        'blocked when 3 tokens have expired'
    );

    my $lockout_expiry = $redis->zscore('P2P::ORDER::VERIFICATION_EVENT', 'LOCKOUT|' . $order->{id} . '|' . $advertiser->loginid);
    cmp_ok $lockout_expiry, '<=', time + (30 * 60), 'lockout expiry is 30 min';

    ok !$redis->exists('P2P::ORDER::VERIFICATION_ATTEMPT::' . $order->{id}), 'attempt key was cleared';
};

subtest 'extend order expiry' => sub {

    set_fixed_time(0);

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2PWithClient::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );

    $client->db->dbic->dbh->do('UPDATE p2p.p2p_order SET expire_time = TO_TIMESTAMP(1200) WHERE id = ' . $order->{id});

    my $redis_item = $order->{id} . '|' . $client->loginid;
    $redis->zadd('P2P::ORDER::EXPIRES_AT', 1200, $redis_item);

    $client->p2p_order_confirm(id => $order->{id});
    exception { $advertiser->p2p_order_confirm(id => $order->{id}) };
    is $redis->zscore('P2P::ORDER::EXPIRES_AT', $redis_item), 1200, 'order expiry time was not extended';

    set_fixed_time(1000);
    $redis->zrem('P2P::ORDER::VERIFICATION_EVENT', 'REQUEST_BLOCK|' . $order->{id} . '|' . $advertiser->loginid);

    exception { $advertiser->p2p_order_confirm(id => $order->{id}) };

    # token expiry time is 1000 + 600 = 1600
    is $redis->zscore('P2P::ORDER::EXPIRES_AT', $redis_item),          1600, 'order expiry time was extended';
    is $advertiser->p2p_order_info(id => $order->{id})->{expiry_time}, 1600, 'order details expiry time is correct';

    exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => 'x') } for (1 .. 3);

    is $redis->zscore('P2P::ORDER::EXPIRES_AT', $redis_item),          1200, 'order expiry time is reset after block';
    is $advertiser->p2p_order_info(id => $order->{id})->{expiry_time}, 1200, 'order details expiry time is correct';
};

subtest 'extend order timeout refund' => sub {

    $config->refund_timeout(1);    # 1 day
    set_fixed_time(10);

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2PWithClient::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );

    $client->db->dbic->dbh->do('UPDATE p2p.p2p_order SET expire_time = TO_TIMESTAMP(10) WHERE id = ' . $order->{id});

    my $redis_item = $order->{id} . '|' . $client->loginid;
    $redis->zadd('P2P::ORDER::TIMEDOUT_AT', 10, $redis_item);

    set_fixed_time(86400 - 3600);    # 23:00
    $client->p2p_order_confirm(id => $order->{id});
    exception { $advertiser->p2p_order_confirm(id => $order->{id}) };
    is $redis->zscore('P2P::ORDER::TIMEDOUT_AT', $redis_item), 10, 'order timedout time was not extended';

    $redis->zrem('P2P::ORDER::VERIFICATION_EVENT', 'REQUEST_BLOCK|' . $order->{id} . '|' . $advertiser->loginid);

    set_fixed_time(86400 - 300);     # 23:55
    exception { $advertiser->p2p_order_confirm(id => $order->{id}) };

    # token expiry time is current time + 600, timeout should be set 1 day before than that
    is $redis->zscore('P2P::ORDER::TIMEDOUT_AT', $redis_item), 300, 'order timedout time was extended';

    exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => 'x') } for (1 .. 3);

    is $redis->zscore('P2P::ORDER::TIMEDOUT_AT', $redis_item), 10, 'order timedout is reset after block';
};

subtest 'verification_pending flag' => sub {
    set_fixed_time(0);

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2PWithClient::create_order(advert_id => $advert->{id});

    ok !exists $order->{verification_pending}, 'flag does not exist on new order';

    $client->p2p_order_confirm(id => $order->{id});
    ok !exists $advertiser->p2p_order_info(id => $order->{id})->{verification_pending}, 'flag does not exist after buyer confirm';

    eval { $advertiser->p2p_order_confirm(id => $order->{id}) };
    is $advertiser->p2p_order_info(id => $order->{id})->{verification_pending}, 1, 'flag is 1 after attempting verification';

    set_fixed_time(601);
    is $advertiser->p2p_order_info(id => $order->{id})->{verification_pending}, 0, 'flag is 0 after token expired';
};

sub check_verification {
    my ($country, $verification) = @_;

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type       => 'buy',
        advertiser => {residence => $country},
    );

    my ($client, $order) = BOM::Test::Helper::P2PWithClient::create_order(
        advert_id  => $advert->{id},
        amount     => $advert->{min_order_amount},
        advertiser => {residence => $country},
    );

    $advertiser->p2p_order_confirm(id => $order->{id});
    my $err = exception { $client->p2p_order_confirm(id => $order->{id}) };

    if ($verification) {
        cmp_deeply($err, {error_code => 'OrderEmailVerificationRequired'}, 'confirmation needed for for buy ad');
    } else {
        is $err, undef, 'no confirmation needed for for buy ad';
    }

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type       => 'sell',
        advertiser => {residence => $country},
    );

    ($client, $order) = BOM::Test::Helper::P2PWithClient::create_order(
        advert_id  => $advert->{id},
        amount     => $advert->{min_order_amount},
        advertiser => {residence => $country},
    );

    $client->p2p_order_confirm(id => $order->{id});
    $err = exception { $advertiser->p2p_order_confirm(id => $order->{id}) };

    if ($verification) {
        cmp_deeply($err, {error_code => 'OrderEmailVerificationRequired'}, 'confirmation needed for for sell ad');
    } else {
        is $err, undef, 'no confirmation needed for for sell ad';
    }
}

done_testing();
