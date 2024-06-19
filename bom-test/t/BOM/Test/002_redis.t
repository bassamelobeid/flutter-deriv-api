use strict;
use warnings;

use BOM::Test;
use Test::More;
use Test::Warnings;
use IO::Async::Loop;
use Net::Async::Redis;
use Data::UUID;
use Syntax::Keyword::Try;
use List::Util qw(first);
use BOM::Config::Redis;

my $expected_redis_index = BOM::Test::on_qa() ? 10 : 0;

# This test uses specific redis_config method and manually creates the RedisDB objects
# Keep in mind redis rpc should be version 6 and for testing the split is logical, we use database 5

TODO: {
    try {
        BOM::Config::Redis::redis_rpc();
        BOM::Config::Redis::redis_rpc_write();
    } catch {
        todo_skip "redis v6 not started yet", 2;
    }

    subtest 'Redis rpc' => sub {
        my $redis_config_re = BOM::Config::Redis::redis_config('rpc', 'read');
        my $redis_re        = RedisDB->new({url => $redis_config_re->{uri}});

        my $redis_config_wr = BOM::Config::Redis::redis_config('rpc', 'write');
        my $redis_wr        = RedisDB->new({url => $redis_config_wr->{uri}});

        isa_ok $redis_re, 'RedisDB';
        isa_ok $redis_wr, 'RedisDB';

        subtest 'Redis Database' => sub {
            is $redis_re->selected_database, $expected_redis_index, 'Correct DB index for RE';
            is $redis_wr->selected_database, $expected_redis_index, 'Correct DB index for WR';
        };

        subtest 'Redis Version' => sub {
            cmp_ok($redis_re->version, '>=', 6, 'Redis version is at least 6.0 for RE');
            cmp_ok($redis_wr->version, '>=', 6, 'Redis version is at least 6.0 for WR');
        };
    };

    # This test uses specific redis_rpc methods
    subtest 'Redis Config RPC' => sub {
        my $redis_rpc_wr = BOM::Config::Redis::redis_rpc_write();
        isa_ok $redis_rpc_wr, 'RedisDB';

        subtest 'Redis Database' => sub {
            is $redis_rpc_wr->selected_database, $expected_redis_index, 'Correct DB index for WR';
        };

        subtest 'Redis Version' => sub {
            cmp_ok($redis_rpc_wr->version, '>=', 6, 'Redis version is at least 6.0 for WR');
        };
    };

}

subtest 'RedisDB database' => sub {
    my $redis = BOM::Config::Redis::redis_mt5_user();
    isa_ok $redis, 'RedisDB';

    subtest 'Redis Database' => sub {
        is $redis->selected_database, $expected_redis_index, 'Correct DB index for WR';
    };
};

subtest 'Net::Async::Redis database' => sub {
    my $loop = IO::Async::Loop->new;
    $loop->add(my $redis = Net::Async::Redis->new(uri => BOM::Config::Redis::redis_config('mt5_user', 'read')->{uri}));
    my $name = Data::UUID->new->create_str();
    $redis->connect->then(
        sub {
            $redis->client_setname($name);
        }
    )->then(
        sub {
            $redis->client_list;
        }
    )->then(
        sub {
            my $list = shift;
            $list =~ /name=$name .* db=(\d+) /;
            is($1, $expected_redis_index, "correct db index");

            Future->done;
        })->get;
};

subtest 'Mojo::Redis2' => sub {
    my $redis = Mojo::Redis2->new(url => BOM::Config::Redis::redis_config('mt5_user', 'read')->{uri});
    my $name  = Data::UUID->new->create_str();
    $redis->client->name($name);
    my $list = $redis->client->list;
    my $info = first { $_->{name} eq $name } values %$list;
    is($info->{db}, $expected_redis_index, 'correct db index');
};

done_testing();
