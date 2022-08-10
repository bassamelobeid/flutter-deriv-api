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
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Database::Model::OAuth;
use BOM::Platform::Token;
use BOM::Platform::Context::Request;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my $emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(emit => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

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
    BOM::Platform::Context::request(BOM::Platform::Context::Request->new({language => 'ES'}));

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
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

    ok my $code = $emitted_events->{p2p_order_confirm_verify}[0]{code}, 'event contains code';

    cmp_deeply(
        $emitted_events,
        {
            p2p_order_confirm_verify => [{
                    loginid          => $advertiser->loginid,
                    code             => re('\w{6}'),
                    order_id         => $order->{id},
                    order_amount     => $order->{amount},
                    buyer_name       => $order->{client_details}->{name},
                    verification_url => "$verification_uri?action=p2p_order_confirm&order_id=$order->{id}&code=$code&lang=ES",
                }
            ],
            p2p_order_updated => [{
                    client_loginid => $advertiser->loginid,
                    order_id       => $order->{id},
                }]
        },
        'p2p_order_confirm_verify event emitted',
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

    ok $redis->exists('P2P::ORDER::VERIFICATION_HISTORY::' . $order->{id}), 'histroy key exists';
    ok $redis->exists('P2P::ORDER::VERIFICATION_ATTEMPT::' . $order->{id}), 'attempts key exists';
    is $client->p2p_order_info(id => $order->{id})->{verification_pending}, 1, 'order info verification pending is still 1';

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

    ok !BOM::Platform::Token->new({token => $code})->token, 'token was deleted';
    ok !$redis->exists('P2P::ORDER::VERIFICATION_HISTORY::' . $order->{id}), 'histroy key was deleted';
    ok !$redis->exists('P2P::ORDER::VERIFICATION_ATTEMPT::' . $order->{id}), 'attempts key was deleted';
    is $client->p2p_order_info(id => $order->{id})->{verification_pending}, 0, 'order info verification pending is now 0';
};

subtest 'bad verification codes' => sub {

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );

    $client->p2p_order_confirm(id => $order->{id});

    undef $emitted_events;

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}) },
        {error_code => 'OrderEmailVerificationRequired'},
        'confirmation needed'
    );

    my $good_code = $emitted_events->{p2p_order_confirm_verify}[0]{code};

    my $bad_code = BOM::Platform::Token->new({
            email       => $advertiser->email,
            created_for => 'payment_withdraw',
        })->token;

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => $bad_code) },
        {error_code => 'InvalidVerificationToken'},
        'cannot use token created for other purpose'
    );

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}) },
        {
            error_code     => 'ExcessiveVerificationRequests',
            message_params => [60]
        },
        'cannot retry within 1 min'
    );

    $redis->del('P2P::ORDER::VERIFICATION_REQUEST::' . $order->{id});

    $bad_code = BOM::Platform::Token->new({
            email       => $client->email,
            created_for => 'p2p_order_confirm',
        })->token;

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => $bad_code) },
        {error_code => 'InvalidVerificationToken'},
        'cannot use token created for other client'
    );

    $redis->del('P2P::ORDER::VERIFICATION_REQUEST::' . $order->{id});

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => rand()) },
        {error_code => 'InvalidVerificationToken'},
        'cannot use random code'
    );

    cmp_deeply(
        exception { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => $good_code) },
        {
            error_code     => 'ExcessiveVerificationFailures',
            message_params => [30],
        },
        'blocked after 3 failures'
    );

    $redis->del('P2P::ORDER::VERIFICATION_LOCKOUT::' . $order->{id});

    lives_ok { $advertiser->p2p_order_confirm(id => $order->{id}, verification_code => $good_code) } 'can confirm after block removed';
};

subtest 'token timeout' => sub {
    set_fixed_time(0);

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
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

        $redis->del('P2P::ORDER::VERIFICATION_REQUEST::' . $order->{id});
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

    is $redis->ttl('P2P::ORDER::VERIFICATION_LOCKOUT::' . $order->{id}), 30 * 60, 'lockout key ttl is 30 min';
    ok !$redis->exists('P2P::ORDER::VERIFICATION_ATTEMPT::' . $order->{id}), 'attempt key was cleared';

};

subtest 'extend order expiry' => sub {
    set_fixed_time(0);

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );

    my $redis_item = $order->{id} . '|' . $client->loginid;
    $redis->zadd('P2P::ORDER::EXPIRES_AT', 1200, $redis_item);

    $client->p2p_order_confirm(id => $order->{id});
    exception { $advertiser->p2p_order_confirm(id => $order->{id}) };
    is $redis->zscore('P2P::ORDER::EXPIRES_AT', $redis_item), 1200, 'order expiry time was not extended';

    set_fixed_time(1000);
    $redis->del('P2P::ORDER::VERIFICATION_REQUEST::' . $order->{id});

    exception { $advertiser->p2p_order_confirm(id => $order->{id}) };

    # token expiry time is 1000 + 600 = 1600
    is $redis->zscore('P2P::ORDER::EXPIRES_AT', $redis_item), 1600, 'order expiry time was extended';
};

subtest 'extend order timeout refund' => sub {

    $config->refund_timeout(1);    # 1 day
    set_fixed_time(10);

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );

    my $redis_item = $order->{id} . '|' . $client->loginid;
    $redis->zadd('P2P::ORDER::TIMEDOUT_AT', 10, $redis_item);

    set_fixed_time(86400 - 3600);    # 23:00
    $client->p2p_order_confirm(id => $order->{id});
    exception { $advertiser->p2p_order_confirm(id => $order->{id}) };
    is $redis->zscore('P2P::ORDER::TIMEDOUT_AT', $redis_item), 10, 'order timedout time was not extended';

    $redis->del('P2P::ORDER::VERIFICATION_REQUEST::' . $order->{id});

    set_fixed_time(86400 - 300);     # 23:55
    exception { $advertiser->p2p_order_confirm(id => $order->{id}) };

    # token expiry time is current time + 600, timeout should be set 1 day before than that
    is $redis->zscore('P2P::ORDER::TIMEDOUT_AT', $redis_item), 300, 'order timedout time was extended';
};

sub check_verification {
    my ($country, $verification) = @_;

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type       => 'buy',
        advertiser => {residence => $country},
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
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

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
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
