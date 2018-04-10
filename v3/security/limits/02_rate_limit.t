use strict;
use warnings;

use Test::Exception;
use Test::More;
use Test::Mojo;
use Test::MockModule;

use Mojo::Redis2;
use Path::Tiny;

my $tmp_dir = Path::Tiny->tempdir(CLEANUP => 1);
my $rate_limits = <<RATE_LIMITS_END;
virtual_buy_transaction:
    1m: 40
    1h: 80
virtual_sell_transaction:
    1m: 40
    1h: 80
virtual_batch_sell:
    1m: 40
    1h: 80
websocket_call:
    1m: 40
    1h: 80
websocket_call_expensive:
    1m: 20
    1h: 40
websocket_call_pricing:
    1m: 30
    1h: 60
websocket_call_email:
    1m: 3
    1h: 5
websocket_call_password:
    1m: 3
    1h: 5
websocket_real_pricing:
    1m: 40
    1h: 80
RATE_LIMITS_END
my $limits_file = path($tmp_dir, 'limits.yaml');
$limits_file->spew($rate_limits);

$ENV{BOM_TEST_RATE_LIMITATIONS} = $limits_file;

my $redis2_module = Test::MockModule->new('Mojo::Redis2');
my @commands_queue;
for my $command (qw/incrby expire ttl/) {
    $redis2_module->mock(
        $command,
        sub {
            note "mocking '$command'";
            push @commands_queue, [$command, @_];
        });
}
my %redis_storage;

our $on_expiry = sub {
    # no-op;
};

my %redis_callbacks = (
    incrby => sub {
        # discard the command itself
        shift;
        my $mock     = shift;
        my $key      = shift;
        my $callback = pop;
        my $value    = shift // 1;
        ($redis_storage{$key}{'value'} //= 0) += $value;
        $redis_storage{$key}{'ttl'} //= -1;
        $callback->($mock, undef, $redis_storage{$key}{'value'});
    },
    expire => sub {
        shift;
        my $mock     = shift;
        my $key      = shift;
        my $callback = pop;
        my $value    = shift // 1;
        $redis_storage{$key}{'ttl'} = $value;

        $on_expiry->(@_);
    },
    ttl => sub {
        shift;
        my $mock     = shift;
        my $key      = shift;
        my $callback = pop;
        my $ttl      = $redis_storage{$key}{'ttl'} // -2;
        $callback->($mock, undef, $ttl);
    },
);

my $process_queue = sub {
    my $count = shift;
    note "processing redis queue";
    $count //= 0;
    my $i = 0;
    while (@commands_queue) {
        return if $count && $i++ == $count;
        my $command_data = shift @commands_queue;
        my $command      = $command_data->[0];
        my $processor    = $redis_callbacks{$command};
        die("No redis processor for '$command'")
            unless $processor;
        note "executing processor for '$command'";
        $processor->(@$command_data);
    }
};

use BOM::Test::Data::Utility::UnitTestRedis;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;

use Binary::WebSocketAPI::Hooks;
use Encode;

use JSON::MaybeXS;
use Mojo::IOLoop::Delay;

my $t = build_wsapi_test();
my $c = $t->app->build_controller;

# stubs
$t->app->helper(app_id               => sub { 1 });
$t->app->helper(rate_limitations_key => sub { "rate_limits::non-authorised::1/md5-hash-of-127.0.0.1" });

subtest "no limit for 'ping' or 'time'" => sub {
    my (@pings, @times);
    for (1 .. 500) {
        push @pings, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'ping', 0);
        push @times, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'time', 0);
    }
    lives_ok { Future->needs_all(@pings, @times)->get };
};

subtest "high real account buy sell pricing limit" => sub {
    my @futures;
    # 10 * 4 = 40, as in limits.yml
    for (1 .. 10) {
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'buy',                    1);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'sell',                   1);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal',               1);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal_open_contract', 1);
    }
    lives_ok { Future->needs_all(@futures)->get } "no limits hit";

    dies_ok { Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal', 1)->get } "limit hit";
};

subtest "hit limits 'proposal' / 'proposal_open_contract' for virtual account" => sub {
    my @futures;
    # 2 * 16 > 30
    for (1 .. 16) {
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal', 0);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal_open_contract', 0);
    }

    dies_ok { Future->needs_all(@futures)->get } "limit hit";
};

subtest "hit limits 'portfolio' / 'profit_table' for virtual account" => sub {
    my @futures;
    # 2 * 10 = 20
    for (1 .. 10) {
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio',    0);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'profit_table', 0);
    }
    lives_ok { Future->needs_all(@futures)->get } "no limits hit";

    dies_ok { Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0)->get } "limit hit";
};

subtest "limits are persisted across connnections for the same client" => sub {
    $process_queue->();

    my $c2 = $t->app->build_controller;
    my $f = Binary::WebSocketAPI::Hooks::reached_limit_check($c2, 'portfolio', 0);
    lives_ok { $f->get } "1st attempt is still allowed";

    $process_queue->();

    $f = Binary::WebSocketAPI::Hooks::reached_limit_check($c2, 'portfolio', 0);
    dies_ok { $f->get } "but not any longer";
};

subtest "get error code (verify_email)" => sub {
    for (my $i = 0; $i < 4; $i++) {
        $t->send_ok({
                json => {
                    verify_email => '12asd',
                    type         => 'account_opening'
                }})->message_ok;
    }
    my $res = JSON::MaybeXS->new->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, 'RateLimit';
};

subtest "expiration of limits" => sub {
    # lets flush redis
    $process_queue->();
    %redis_storage = ();

    my $f1 = Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0);
    Mojo::IOLoop->one_tick while !$f1->is_ready;
    ok $f1->is_failed, "limit hit (we are still 1 step ahead of redis data)";
    # trigger updates of internals
    $process_queue->();

    my $f2 = Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0);
    Mojo::IOLoop->one_tick while !$f2->is_ready;
    ok $f2->is_done, "no limit hit";
};

subtest "post-expiration of limits under heavy load" => sub {
    # lets flush redis
    $process_queue->();
    %redis_storage = ();

    # testing scenario:
    # 1. hit service
    # 2. put 2 pending service hits into queue
    # 3. wait 1st hit to be expired
    # 4. check that pending hits will set expiration too
    #
    # This reflects real-world scenarion, when under heavy load
    # there might be more then one pending service hits, meanwhile
    # the limits value already expires in redis, when pending hits
    # are send to redis.

    my $expiration_sets = 0;
    local $on_expiry = sub {
        ++$expiration_sets;
    };

    my $c2 = $t->app->build_controller;

    my @futures = (
        Binary::WebSocketAPI::Hooks::reached_limit_check($c2, 'portfolio', 0),
        Binary::WebSocketAPI::Hooks::reached_limit_check($c2, 'portfolio', 0),
        Binary::WebSocketAPI::Hooks::reached_limit_check($c2, 'portfolio', 0),
    );
    lives_ok { $futures[0]->get } "no limits hit";
    # process 2 incr-by (hourly and minutely)
    $process_queue->(2);

    my @cmds = @commands_queue;
    @commands_queue = grep { $_->[0] eq 'expire' } @cmds;

    # process 2 expirations (hourly and minutely)
    $process_queue->(2);
    is $expiration_sets, 2;

    note "keys :" . join(", ", keys %redis_storage);
    $redis_storage{$_}{'value'} = 0 for (keys %redis_storage);

    @commands_queue = grep { $_->[0] ne 'expire' } @cmds;
    # process incrs
    $process_queue->();
    # and (expected) expirations
    $process_queue->();
    is $expiration_sets, 4;

};

subtest "keys without expiry" => sub {
    # Flush redis
    $process_queue->();
    %redis_storage = ();

    my $expiration_sets = 0;
    local $on_expiry = sub {
        ++$expiration_sets;
    };

    # trigger limit check
    Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0)->get;
    $process_queue->();

    # confirm ttl is set.
    isnt $redis_storage{$_}{'ttl'}, -1 for (keys %redis_storage);
    # confirm expire called 2 times.
    is $expiration_sets, 2;

    # unset all ttls
    $redis_storage{$_}{'ttl'} = -1 for (keys %redis_storage);

    # trigger a second limit check
    Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0)->get;
    $process_queue->();

    # confirm all ttls is set
    isnt $redis_storage{$_}{'ttl'}, -1 for (keys %redis_storage);
    # confirm that expire has been called 4 times (2 times initially and 2 times to reset ttl)
    is $expiration_sets, 4;
};

$t->finish_ok;

done_testing();
