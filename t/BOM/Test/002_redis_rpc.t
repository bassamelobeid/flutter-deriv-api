use strict;
use warnings;

use BOM::Test;
use Test::More;
use Test::Warnings;

use BOM::Config::Redis;

if (BOM::Test::on_qa) {

    # This test uses specific redis_config method and manually creates the RedisDB objects
    # Keep in mind redis rpc should be version 6 and for testing the split is logical, we use database 5

    subtest 'Redis Config' => sub {
        my $redis_config_wr = BOM::Config::Redis::redis_config('rpc', 'write');
        ok $redis_config_wr->{uri} =~ qr/db=5/, 'Test database in redis uri';
        my $redis_wr = RedisDB->new({url => $redis_config_wr->{uri}});
        isa_ok $redis_wr, 'RedisDB';

        subtest 'Redis Database' => sub {
            is $redis_wr->selected_database, 5, 'Correct DB index for WR';
        };

        subtest 'Redis Version' => sub {
            cmp_ok($redis_wr->version, '>=', 6, 'Redis version is at least 6.0 for WR');
        };
    };

    # This test uses specific redis_rpc methods

    subtest 'Redis Config RPC' => sub {
        my $redis_rpc_wr = BOM::Config::Redis::redis_rpc_write();
        isa_ok $redis_rpc_wr, 'RedisDB';

        subtest 'Redis Database' => sub {
            is $redis_rpc_wr->selected_database, 5, 'Correct DB index for WR';
        };

        subtest 'Redis Version' => sub {
            cmp_ok($redis_rpc_wr->version, '>=', 6, 'Redis version is at least 6.0 for WR');
        };
    };
} else {
    ok 1, "Tests skipped because weren't in QA environment.";
}

done_testing();
