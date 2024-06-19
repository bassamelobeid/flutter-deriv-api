use strict;
use warnings;

use Date::Utility;
use Data::Dumper;
use Test::MockModule;
use Test::MockTime qw(set_fixed_time);
use Test::More;
use Test::Exception;
use Syntax::Keyword::Try;
use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Helper::Client     qw(create_client);
use BOM::Event::NotificationsService;

use constant SEPARATOR                 => '::';
use constant DAY_IN_SECONDS            => 24 * 60 * 60;
use constant DC_NOTICE_TIME_IN_SECONDS => 60;

my $notification_queue             = join(SEPARATOR, 'NOTIFICATION_QUEUE',      uc DateTime->now()->day_name);
my $notification_queue_done        = join(SEPARATOR, 'NOTIFICATION_QUEUE_DONE', uc DateTime->now()->day_name);
my $notification_mul_dc_queue      = 'NOTIFICATION_MUL_DC_QUEUE';
my $notification_mul_dc_queue_done = join(SEPARATOR, 'NOTIFICATION_MUL_DC_QUEUE_DONE', uc DateTime->now()->day_name);

my $client = create_client();
$client->payment_free_gift(
    currency => 'USD',
    amount   => 5000,
    remark   => 'free gift',
);
my $account = $client->account('USD');
my $dbc     = $client->db->dbic;

my $connection_builder = BOM::Database::ClientDB->new({broker_code => 'CR'});

sub _create_multiplier_contract {
    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $account->client_loginid,
                currency_code  => $account->currency_code,
            },
            bet_data => {
                underlying_symbol     => 'R_100',
                payout_price          => 0.00,
                buy_price             => 11.05,
                remark                => 'Test Remark',
                purchase_time         => '2021-11-29 08:01:37',
                start_time            => '2021-11-29 08:01:37',
                expiry_time           => '2121-11-05 08:01:37',
                settlement_time       => '2121-11-06 00:00:00',
                is_expired            => 0,
                is_sold               => 0,
                bet_class             => 'multiplier',
                bet_type              => 'MULTUP',
                multiplier            => 100,
                basis_spot            => 9980.09,
                stop_out_order_date   => '2021-11-29 08:34:45',
                stop_out_order_amount => -10.0,
                commission            => 0.00050,
                short_code            => 'MULTUP_R_100_10.00_100_1638172897_4791830399_5m_0.00',
            },
            db => $connection_builder->db,
        });

    my ($fmb, $txn) = $financial_market_bet_helper->buy_bet;

    return $fmb->{id};
}

sub _create_non_multiplier_contract {
    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $account->client_loginid,
                currency_code  => $account->currency_code,
            },
            bet_data => {
                underlying_symbol => '1HZ100V',
                payout_price      => 39.07,
                buy_price         => 20.00,
                remark            => 'Test Remark',
                purchase_time     => '2021-12-06 11:12:00',
                start_time        => '2021-12-06 11:12:00',
                expiry_time       => '2021-12-06 11:12:05',
                settlement_time   => '2021-12-06 11:12:05',
                is_expired        => 0,
                is_sold           => 0,
                tick_count        => 5,
                bet_class         => 'higher_lower_bet',
                bet_type          => 'CALL',
                short_code        => 'CALL_1HZ100V_39.07_1638789120_5T_S0P_0',
            },
            db => $connection_builder->db,
        });

    my ($fmb, $txn) = $financial_market_bet_helper->buy_bet;

    return $fmb->{id};
}

subtest 'Throws error with wrong args' => sub {
    throws_ok(sub { BOM::Event::NotificationsService->new() }, qr/redis is required/, 'redis instance is required');
};

subtest 'Send notification for multiplier contracts successfully ' => sub {
    my $login_id    = $account->client_loginid;
    my $contract_id = _create_multiplier_contract();

    my $mocked_redis         = Test::MockModule->new('BOM::Config::Redis');
    my $mocked_event_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');

    my $original_cid = join('::', $contract_id, $login_id, 'USD');

    $mocked_redis->mock(
        'spop',
        sub {
            my ($self, $queue) = @_;

            is($queue, $notification_queue);

            return $original_cid;
        });

    $mocked_redis->mock(
        'sismember',
        sub {
            my ($self, $queue, $cid) = @_;

            is($cid,   $original_cid,            'Check sismember cid argument.');
            is($queue, $notification_queue_done, 'Check sismember queue argument.');

            return 0;
        });

    $mocked_redis->mock(
        'exists',
        sub {
            my ($self, $queue) = @_;

            is($queue, $notification_queue_done, 'Checking queue name parameter in exist command.');

            return 1;
        });

    $mocked_redis->mock(
        'sadd',
        sub {
            my ($self, $queue, $cid) = @_;

            is($queue, $notification_queue_done, 'Checking queue name parameter in sadd command.');
            is($cid,   $original_cid,            'Checking cid parameter in sadd command.');

            return 1;
        });

    $mocked_event_emitter->mock(
        'emit',
        sub {
            my ($event_name, $args) = @_;

            is($event_name,          'multiplier_near_expire_notification', 'Correct event name sent to event emitter.');
            is($args->{loginid},     $login_id,                             'Correct login_id sent to event emitter.');
            is($args->{contract_id}, $contract_id,                          'Correct contract_id sent to event emitter.');

            return 1;
        });

    my $notifications_service = BOM::Event::NotificationsService->new(redis => 'BOM::Config::Redis');

    $notifications_service->dequeue_notifications();
};

subtest 'Do not send notification for non multiplier bet class' => sub {
    my $login_id    = $account->client_loginid;
    my $contract_id = _create_non_multiplier_contract();

    my $mocked_redis = Test::MockModule->new('BOM::Config::Redis');
    my $original_cid = join('::', $contract_id, $login_id, 'USD');

    $mocked_redis->mock(
        'spop',
        sub {
            my ($self, $queue) = @_;

            is($queue, $notification_queue);

            return $original_cid;
        });

    $mocked_redis->mock(
        'sismember',
        sub {
            my ($self, $queue, $cid) = @_;

            is($cid,   $original_cid,            'Check sismember cid argument.');
            is($queue, $notification_queue_done, 'Check sismember queue argument.');

            return 0;
        });

    $mocked_redis->mock(
        'exists',
        sub {
            my ($self, $queue) = @_;

            is($queue, $notification_queue_done, 'Checking queue name parameter in exist command.');

            return 1;
        });

    $mocked_redis->mock(
        'sadd',
        sub {
            my ($self, $queue, $cid) = @_;

            is($queue, $notification_queue_done, 'Checking queue name parameter in sadd command.');
            is($cid,   $original_cid,            'Checking cid parameter in sadd command.');

            return 1;
        });

    my $emit_called           = 0;
    my $event_emitter         = \&BOM::Platform::Event::Emitter;
    my $notifications_service = BOM::Event::NotificationsService->new(redis => 'BOM::Config::Redis');

    {
        no warnings 'redefine';
        *BOM::Platform::Event::Emitter = sub { ++$emit_called; goto &$event_emitter };
    }

    $notifications_service->dequeue_notifications();
    ok(not($emit_called), 'Emit function has not been called.');
};

subtest 'Send notification for expiring deal cancellation contracts successfully' => sub {
    set_fixed_time(1638871863);

    my $login_id    = $account->client_loginid;
    my $contract_id = _create_multiplier_contract();

    my $mocked_redis         = Test::MockModule->new('BOM::Config::Redis');
    my $mocked_event_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');

    my $original_cid = join('::', $contract_id, $login_id, 'USD');

    $mocked_redis->mock(
        'zrangebyscore',
        sub {
            my ($self, $queue, $min, $max) = @_;

            is($queue, $notification_mul_dc_queue, 'Correct queue name is received by zrangebyscore.');
            is($min,   time,                       'Correct minimum score is received by zrangebyscore.');
            is($max,   time + 60,                  'Correct maximum score is received by zrangebyscore.');

            return [$original_cid];
        });

    $mocked_redis->mock(
        'sismember',
        sub {
            my ($self, $queue, $cid) = @_;

            is($cid,   $original_cid,                   'Check sismember cid argument in dequeue_dc_notifications.');
            is($queue, $notification_mul_dc_queue_done, 'Check sismember queue argument in dequeue_dc_notifications.');

            return 0;
        });

    $mocked_event_emitter->mock(
        'emit',
        sub {
            my ($event_name, $args) = @_;

            is($event_name,          'multiplier_near_dc_notification', 'Correct event name for dc sent to event emitter.');
            is($args->{loginid},     $login_id,                         'Correct login_id for dc sent to event emitter.');
            is($args->{contract_id}, $contract_id,                      'Correct contract_id for dc sent to event emitter.');

            return 1;
        });

    $mocked_redis->mock(
        'zrem',
        sub {
            my ($self, $queue, $cid) = @_;

            is($cid,   $original_cid,              'Check zrem cid argument in dequeue_dc_notifications.');
            is($queue, $notification_mul_dc_queue, 'Check zrem queue argument in dequeue_dc_notifications.');

            return 1;
        });

    $mocked_redis->mock(
        'exists',
        sub {
            my ($self, $queue) = @_;

            is($queue, $notification_mul_dc_queue_done, 'Checking multiplier dc queue name in exists command.');

            return 1;
        });

    $mocked_redis->mock(
        'sadd',
        sub {
            my ($self, $queue, $cid) = @_;

            is($queue, $notification_mul_dc_queue_done, 'Checking multiplier dc queue name in sadd command.');
            is($cid,   $original_cid,                   'Checking multiplier dc cid in sadd command.');

            return 1;
        });

    my $notifications_service = BOM::Event::NotificationsService->new(redis => 'BOM::Config::Redis');

    $notifications_service->dequeue_dc_notifications();
};

subtest 'Do not send notifications for the already processed job' => sub {
    set_fixed_time(1638871863);

    my $login_id    = $account->client_loginid;
    my $contract_id = _create_multiplier_contract();

    my $mocked_redis = Test::MockModule->new('BOM::Config::Redis');

    my $original_cid = join('::', $contract_id, $login_id, 'USD');

    $mocked_redis->mock(
        'zrangebyscore',
        sub {
            my ($self, $queue, $min, $max) = @_;

            is($queue, $notification_mul_dc_queue,       'Correct queue name is received by zrangebyscore.');
            is($min,   time,                             'Correct minimum score is received by zrangebyscore.');
            is($max,   time + DC_NOTICE_TIME_IN_SECONDS, 'Correct maximum score is received by zrangebyscore.');

            return [$original_cid];
        });

    $mocked_redis->mock(
        'sismember',
        sub {
            my ($self, $queue, $cid) = @_;

            is($cid,   $original_cid,                   'Check sismember cid argument in dequeue_dc_notifications.');
            is($queue, $notification_mul_dc_queue_done, 'Check sismember queue argument in dequeue_dc_notifications.');

            return 1;
        });

    my $notifications_service = BOM::Event::NotificationsService->new(redis => 'BOM::Config::Redis');

    $notifications_service->dequeue_dc_notifications();
};

done_testing;
