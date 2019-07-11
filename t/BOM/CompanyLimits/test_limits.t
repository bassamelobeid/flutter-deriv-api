#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 7;
use BOM::Test;
use Test::Exception;
use Data::Dumper;

use Test::MockModule;
use BOM::CompanyLimits::Limits;
use BOM::Config::RedisReplicated;
use Date::Utility;
# TODO: error validations for each function
# TODO: write helper for test case such as encoding
# TODO: add error messages

subtest '_add_limit_value', sub {
    # TODO: make testcase more indendent instead of having to rely on previous output
    my $limit = BOM::CompanyLimits::Limits::_add_limit_value(10000, 1561801504, 1561801810);
    is_deeply($limit, [10000, 1561801504, 1561801810], 'first limit, return itself');

    $limit = [10000, 1561801504, 1561801810];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value(10, 0, 0, $limit);
    is_deeply($limit, [10, 0, 0, 10000, 1561801504, 1561801810], 'smallest limit, inserted into front');

    $limit = [10, 0, 0, 10000, 1561801504, 1561801810];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value(30, 1261801504, 1961801810, $limit);
    is_deeply($limit, [10, 0, 0, 30, 1261801504, 1961801810, 10000, 1561801504, 1561801810], 'middle limit');

    $limit = [10, 0, 0, 30, 1261801504, 1961801810, 10000, 1561801504, 1561801810];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value(30, 1061801504, 1661801810, $limit);
    is_deeply(
        $limit,
        [10, 0, 0, 30, 1261801504, 1961801810, 30, 1061801504, 1661801810, 10000, 1561801504, 1561801810],
        'same limit, position does not matter for this case'
    );

    $limit = [10, 0, 0, 30, 1261801504, 1961801810, 30, 1061801504, 1661801810, 10000, 1561801504, 1561801810];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value(20000, 1061801504, 1661801810, $limit);
    is_deeply(
        $limit,
        [10, 0, 0, 30, 1261801504, 1961801810, 30, 1061801504, 1661801810, 10000, 1561801504, 1561801810, 20000, 1061801504, 1661801810],
        'same limit, position does not matter for this case'
    );

    $limit = [5, 1261801504, 1961801810];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value(559, 1561801504, 1961801810, $limit);
    is_deeply($limit, [5, 1261801504, 1961801810, 559, 1561801504, 1961801810], 'largest limit, insert at the end');

    $limit = [10, 1261801504, 1961801810];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value(10, 0, 0, $limit);
    is_deeply($limit, [10, 1261801504, 1961801810, 10, 0, 0], '');
};

subtest '_encode_limit and _decode_limit', sub {
    my $encoded = BOM::CompanyLimits::Limits::_encode_limit(1, 10000, 1561801504, 1561801810);
    my $decoded = BOM::CompanyLimits::Limits::_decode_limit($encoded);
    is_deeply($decoded, [1, 10000, 1561801504, 1561801810], 'there is only one type of limit, so no need to specify offset');

    $encoded =
        BOM::CompanyLimits::Limits::_encode_limit(2, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810);
    $decoded = BOM::CompanyLimits::Limits::_decode_limit($encoded);
    is_deeply(
        $decoded,
        [2, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810],
        'there is two type of limit, so need to specify the 1 offset and all the remaining limits'
    );

    $encoded =
        BOM::CompanyLimits::Limits::_encode_limit(4, 2, 3, 4, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810,
        700, 1261801504, 2061801504);
    $decoded = BOM::CompanyLimits::Limits::_decode_limit($encoded);
    is_deeply(
        $decoded,
        [4, 2, 3, 4, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504],
        'there is four type of limit, so need to specify the 3 offset and all the remaining limits'
    );
};

subtest '_extract_limit_by_group and _collapse_limit_by_group', sub {
    my $extracted = BOM::CompanyLimits::Limits::_extract_limit_by_group(1, 10000, 1561801504, 1561801810);
    is_deeply($extracted, [[10000, 1561801504, 1561801810]], '');

    my $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed, [1, 10000, 1561801504, 1561801810], '');

    $extracted = BOM::CompanyLimits::Limits::_extract_limit_by_group(2, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504,
        1961801810);
    is_deeply($extracted, [[10000, 1561801504, 1561801810, 559, 1561801504, 1961801810], [30, 1261801504, 1961801810]], '');
    $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed, [2, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810], '');

    $extracted =
        BOM::CompanyLimits::Limits::_extract_limit_by_group(4, 2, 3, 4, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504,
        1961801810, 700, 1261801504, 2061801504);
    is_deeply($extracted,
        [[10000, 1561801504, 1561801810, 559, 1561801504, 1961801810], [30, 1261801504, 1961801810], [700, 1261801504, 2061801504], []], '');
    $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed,
        [4, 2, 3, 4, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504], '');

    $extracted =
        BOM::CompanyLimits::Limits::_extract_limit_by_group(4, 1, 2, 3, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504,
        1961801810, 700, 1261801504, 2061801504);
    is_deeply($extracted,
        [[10000, 1561801504, 1561801810], [559, 1561801504, 1961801810], [30, 1261801504, 1961801810], [700, 1261801504, 2061801504]], '');
    $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed,
        [4, 1, 2, 3, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504], '');

    $extracted =
        BOM::CompanyLimits::Limits::_extract_limit_by_group(4, 4, 4, 4, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504,
        1961801810, 700, 1261801504, 2061801504);
    is_deeply($extracted,
        [[10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504], [], [], []], '');
    $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed,
        [4, 4, 4, 4, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504], '');

};

my $mock_redis = Test::MockModule->new('RedisDB');
subtest '_get_decoded_limit', sub {
    $mock_redis->mock(
        hget => sub {
            return BOM::CompanyLimits::Limits::_encode_limit(4, 1, 2, 3, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504,
                1961801810, 700, 1261801504, 2061801504);
        });
    my $decoded = BOM::CompanyLimits::Limits::_get_decoded_limit('frxUSDJPY,,,t');
    is_deeply($decoded,
        [4, 1, 2, 3, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504], '');
    $mock_redis->unmock('hget');
};

subtest 'process_and_get_active_limit', sub {
    my $mock_date_util = Test::MockModule->new('Date::Utility');

    $mock_date_util->mock(epoch => sub { return 1600000000; });
    my $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit(
        [30, 1400000000, 1500000000, 40, 1500000000, 1700000000, 60, 1800000000, 1900000000]);
    is $active_lim, 40, 'present limit';
    $mock_date_util->unmock('epoch');

    $mock_date_util->mock(epoch => sub { return 1750000000; });
    $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit(
        [30, 1400000000, 1500000000, 40, 1500000000, 1700000000, 60, 1800000000, 1900000000]);
    is $active_lim, "inf", 'future limits';
    $mock_date_util->unmock('epoch');

    $mock_date_util->mock(epoch => sub { return 1750000000; });
    $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit(
        [30, 1400000000, 1500000000, 40, 1500000000, 1700000000, 60, 1800000000, 1900000000, 80, 0, 0]);
    is $active_lim, 80, 'indefinite limit';
    $mock_date_util->unmock('epoch');

    $mock_date_util->mock(epoch => sub { return 2000000000; });
    $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit(
        [30, 1400000000, 1500000000, 40, 1500000000, 1700000000, 60, 1800000000, 1900000000]);
    is $active_lim, undef, 'every limit are past';

    $mock_date_util->mock(epoch => sub { return 2000000000; });
    $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit([]);
    is $active_lim, undef, 'no limits given';
    $mock_date_util->unmock('epoch');
};

subtest 'add_limit and get_limit', sub {
    my ($loss_type, $key, $amount, $start_epoch, $end_epoch) = @_;

    # TODO: do a for loop through the whole thing per underlying group
    # TODO: add get_limit test
    # TODO: test get_limit

    $mock_redis->mock(hget => sub { return BOM::CompanyLimits::Limits::_encode_limit(1, 10000, 1561801504, 1561801810); });
    my $limit = BOM::CompanyLimits::Limits::add_limit('POTENTIAL_LOSS', 'frxUSDJPY,,,t', 39, 1561801504, 1561801810);
    cmp_ok $limit, 'eq', '1 39 1561801504 1561801810 10000 1561801504 1561801810', '';
    $mock_redis->unmock('hget');

    $mock_redis->mock(hget => sub { return BOM::CompanyLimits::Limits::_encode_limit(1, 39, 1561801504, 1561801810, 10000, 1561801504, 1561801810); }
    );
    $limit = BOM::CompanyLimits::Limits::add_limit('POTENTIAL_LOSS', 'frxUSDJPY,,,t', 10, 0, 0);
    cmp_ok $limit, 'eq', '1 10 0 0 39 1561801504 1561801810 10000 1561801504 1561801810', '';
    $mock_redis->unmock('hget');

    $mock_redis->mock(
        hget => sub { return BOM::CompanyLimits::Limits::_encode_limit(1, 10, 0, 0, 39, 1561801504, 1561801810, 10000, 1561801504, 1561801810); });
    $limit = BOM::CompanyLimits::Limits::add_limit('POTENTIAL_LOSS', 'frxUSDJPY,,,t', 30, 1261801504, 1961801810);
    cmp_ok $limit, 'eq', '1 10 0 0 30 1261801504 1961801810 39 1561801504 1561801810 10000 1561801504 1561801810', '';
    $mock_redis->unmock('hget');

};

done_testing();
