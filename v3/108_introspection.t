use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use BOM::Platform::RedisReplicated;
use Sereal::Encoder;
use Test::More;
use Test::MockTime qw/:all/;
use Test::MockModule;

use Date::Utility;

use File::Temp;
use Future;
use Future::Mojo;
use JSON;
use Socket qw(PF_INET SOCK_STREAM pack_sockaddr_in inet_aton);
use Try::Tiny;
use Variable::Disposition qw(retain_future);

use Quant::Framework;

use BOM::Database::Model::OAuth;
use BOM::MarketData qw(create_underlying);
use BOM::Test::Helper qw/reconnect test_schema build_wsapi_test/;
use BOM::Platform::RedisReplicated;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Platform::Chronicle;

use await;

initialize_realtime_ticks_db();

my $t = build_wsapi_test();
note "Daemon started\n";

my $intro_port;
for (@{$t->app->log->history}) {
    if ($_->[2] =~ /Introspection[^:]+:(\d+)/) {
        $intro_port = $1;
        last;
    }
}
die "Introspection server port not found!" unless $intro_port;
note "Introspection port: $intro_port\n";

socket(my $socket, PF_INET, SOCK_STREAM, 0)
    or die "socket: $!";
connect($socket, pack_sockaddr_in($intro_port, inet_aton("localhost")))
    or die "connect: $!";

my ($res, $ticks, $intro_stats, $intro_conn);

my $now  = Date::Utility->new;
my $time = $now->epoch;
my @ticks;
for (my $i = $time - 1800; $i <= $time; $i += 15) {
    push @ticks,
        +{
        epoch          => $i,
        decimate_epoch => $i,
        quote          => 100 + rand(0.0001)};
}
my $redis   = BOM::Platform::RedisReplicated::redis_write();
my $encoder = Sereal::Encoder->new({
    canonical => 1,
});

$redis->zadd('DECIMATE_frxUSDJPY_15s_DEC', $_->{epoch}, $encoder->encode($_)) for @ticks;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(USD JPY JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    quote      => 100,
    epoch      => $now->epoch - 1,
    underlying => 'frxUSDJPY',
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    quote      => 101,
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    quote      => 102,
    epoch      => $now->epoch + 1,
    underlying => 'frxUSDJPY',
});

# prepare client
my $email  = 'test-binary-introspection@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->set_status('tnc_approval', 'system', BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

$client->set_default_account('USD');
$client->smart_payment(
    currency     => 'USD',
    amount       => +300000,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

my $authorize = $t->await::authorize({authorize => $token});

my $underlying = create_underlying('frxUSDJPY');

## stats

# cumulative_client_connections

$t->await::ping({ping => 1});
$intro_stats = send_introspection_cmd('stats');
cmp_ok $intro_stats->{cumulative_client_connections}, '==', 1, "1 cumulative_client_connections";
reconnect($t, {app_id => 2});
note "RECONNECTED\n";
$t->await::ping({ping => 1});
$intro_stats = send_introspection_cmd('stats');
cmp_ok $intro_stats->{cumulative_client_connections}, '==', 2, "2 cumulative_client_connections";

# number of redis connections

my %contract = (
    "amount"        => "100",
    "basis"         => "payout",
    "contract_type" => "CALL",
    "currency"      => "USD",
    "symbol"        => "frxUSDJPY",
    "duration"      => "7",
    "duration_unit" => "d",
    "subscribe"     => 1,
);

my $req_id = 0;

$t->await::proposal({
    proposal => 1,
    req_id   => ++$req_id,
    %contract
});

subtest "redis errors" => sub {
    $t->app->stat->{redis_errors}++;
    my $intro_stats = send_introspection_cmd('stats');
    cmp_ok $intro_stats->{cumulative_redis_errors}, '>', 0, 'Got redis error';
};

## connections

# last sent and recieved message

$t->await::time({time => 1});
$intro_conn = send_introspection_cmd('connections');
ok $intro_conn->{connections}[0]{last_call_received_from_client}{time}, 'last msg was time';
$t->await::ping({ping => 1});
$intro_conn = send_introspection_cmd('connections');
cmp_ok $intro_conn->{connections}[0]{last_message_sent_to_client}{ping}, 'eq', 'pong', 'last msg was pong';

# count of each type
cmp_ok $intro_conn->{connections}[0]{messages_received_from_client}{time}, '==', 1, '1 time call';
cmp_ok $intro_conn->{connections}[0]{messages_sent_to_client}{time},       '==', 1, '1 time reply';
$t->await::time({time => 1});
$intro_conn = send_introspection_cmd('connections');
cmp_ok $intro_conn->{connections}[0]{messages_received_from_client}{time}, '==', 2, '2 time call';
cmp_ok $intro_conn->{connections}[0]{messages_sent_to_client}{time},       '==', 2, '2 time reply';

my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader());

SKIP: {
    skip 'Forex test does not work on the weekends.', 1 if not $trading_calendar->is_open_at($underlying->exchange, Date::Utility->new);

    # number of pricer subs
    subtest "pricers subscriptions" => sub {

        sub do_proposal {
            my $expected_err = shift;
            my $res          = $t->await::proposal({
                proposal => 1,
                req_id   => ++$req_id,
                %contract
            });

            return do_proposal($expected_err) if $res->{req_id} != $req_id;
            is $res->{error}{message}, $expected_err, 'got expected error for proposal call';
        }

        do_proposal('You are already subscribed to proposal.');
        my $intro_conn = send_introspection_cmd('connections');
        cmp_ok $intro_conn->{connections}[0]{pricer_subscription_count}, '==', 1, 'current 1 price subscription';

        $contract{amount} = 200;
        do_proposal();
        $intro_conn = send_introspection_cmd('connections');
        cmp_ok $intro_conn->{connections}[0]{pricer_subscription_count}, '==', 1, 'current 1 price subscription';

        $contract{duration} = 14;
        do_proposal();
        $intro_conn = send_introspection_cmd('connections');
        cmp_ok $intro_conn->{connections}[0]{pricer_subscription_count}, '==', 2, 'now 2 price subscription';

        $t->await::forget_all({
            forget_all => 'proposal',
            req_id   => ++$req_id,
        });
        $intro_conn = send_introspection_cmd('connections');
        cmp_ok $intro_conn->{connections}[0]{pricer_subscription_count}, '==', 0, 'no more price subscription';
    };
}

done_testing;

sub send_introspection_cmd {
    my $cmd = shift;
    my $ret;
    my $VAR1;
    retain_future(
        Future->done(
            try {
                my $stream = Mojo::IOLoop::Stream->new($socket);
                $stream->start;
                $stream->on(
                    read => sub {
                        ($stream, $ret) = @_;
                        $stream->close;
                        Mojo::IOLoop->stop;
                        Future->done;
                    });
                $stream->write("$cmd\n");
                Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
            }));
    $ret = substr($ret, 5);         # remove 'OK - '
    $ret = JSON::from_json($ret);
    return $ret;
}
