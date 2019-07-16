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
# TODO: nuke all redis limits keys used in the algo to test things out.

sub _clean_redis {
    BOM::Config::RedisReplicated::redis_limits_write->flushall();
}

subtest '_add_limit_value', sub {
    # TODO: make testcase more indendent instead of having to rely on previous output
    my $limit = BOM::CompanyLimits::Limits::_add_limit_value([10000, 1500000000, 1600000000]);
    is_deeply($limit, [10000, 1500000000, 1600000000], '');

    $limit = [10000, 1700000000, 1800000000];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value([10, 0, 0, $limit]);
    is_deeply($limit, [10, 0, 0, 10000, 1700000000, 1800000000], '');

    $limit = [10, 0, 0, 10000, 1700000000, 1800000000];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value([30, 1500000000, 1600000000, $limit]);
    is_deeply($limit, [10, 0, 0, 30, 1500000000, 1600000000, 10000, 1700000000, 1800000000], '');

    $limit = [10, 0, 0, 30, 1500000000, 1600000000, 10000, 1500000000, 1600000000];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value([30, 1000000000, 1600000000, $limit]);
    is_deeply($limit, [10, 0, 0, 30, 1500000000, 1600000000, 30, 1000000000, 1600000000, 10000, 1500000000, 1600000000], '');

    $limit = [10, 0, 0, 30, 1500000000, 1600000000, 30, 1000000000, 1600000000, 10000, 1500000000, 1600000000];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value([20000, 1200000000, 1900000000, $limit]);
    is_deeply($limit,
        [10, 0, 0, 30, 1500000000, 1600000000, 30, 1000000000, 1600000000, 10000, 1500000000, 1600000000, 20000, 1200000000, 1900000000], '');

    $limit = [5, 1200000000, 1900000000];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value([559, 1500000000, 1800000000, $limit]);
    is_deeply($limit, [5, 1200000000, 1900000000, 559, 1500000000, 1800000000], '');

    $limit = [10, 1200000000, 1900000000];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value([10, 0, 0, $limit]);
    is_deeply($limit, [10, 1200000000, 1900000000, 10, 0, 0], '');

    $limit = [10, 1200000000, 1900000000];
    $limit = BOM::CompanyLimits::Limits::_add_limit_value([10, 1200000000, 1900000000, $limit]);
    is_deeply($limit, [10, 1200000000, 1900000000], 'trying to add limit that have the same amount, start, and end, this will not work');
};

subtest '_encode_limit and _decode_limit', sub {
    my $encoded = BOM::CompanyLimits::Limits::_encode_limit([1, 10000, 1300000000, 1700000000]);
    my $decoded = BOM::CompanyLimits::Limits::_decode_limit($encoded);
    is_deeply($decoded, [1, 10000, 1300000000, 1700000000], 'there is only one type of limit, so no need to specify offset');

    $encoded =
        BOM::CompanyLimits::Limits::_encode_limit([2, 2, 10000, 1300000000, 1700000000, 559, 1500000000, 1900000000, 30, 1200000000, 1900000000]);
    $decoded = BOM::CompanyLimits::Limits::_decode_limit($encoded);
    is_deeply(
        $decoded,
        [2, 2, 10000, 1300000000, 1700000000, 559, 1500000000, 1900000000, 30, 1200000000, 1900000000],
        'there is two type of limit, so need to specify the 1 offset and all the remaining limits'
    );

    $encoded =
        BOM::CompanyLimits::Limits::_encode_limit(
        [4, 2, 3, 4, 10000, 1300000000, 1700000000, 559, 1500000000, 1900000000, 30, 1200000000, 1900000000, 700, 1200000000, 2000000000]);
    $decoded = BOM::CompanyLimits::Limits::_decode_limit($encoded);
    is_deeply(
        $decoded,
        [4, 2, 3, 4, 10000, 1300000000, 1700000000, 559, 1500000000, 1900000000, 30, 1200000000, 1900000000, 700, 1200000000, 2000000000],
        'there is four type of limit, so need to specify the 3 offset and all the remaining limits'
    );
};

subtest '_extract_limit_by_group and _collapse_limit_by_group', sub {
    my $extracted = BOM::CompanyLimits::Limits::_extract_limit_by_group([1, 10000, 1500000000, 1600000000]);
    is_deeply($extracted, [[10000, 1500000000, 1600000000]], '');

    my $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed, [1, 10000, 1500000000, 1600000000], '');

    $extracted = BOM::CompanyLimits::Limits::_extract_limit_by_group(
        [2, 2, 10000, 1500000000, 1600000000, 559, 1600000000, 1700000000, 30, 1800000000, 1900000000]);
    is_deeply($extracted, [[10000, 1500000000, 1600000000, 559, 1600000000, 1700000000], [30, 1800000000, 1900000000]], '');
    $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed, [2, 2, 10000, 1500000000, 1600000000, 559, 1600000000, 1700000000, 30, 1800000000, 1900000000], '');

    $extracted =
        BOM::CompanyLimits::Limits::_extract_limit_by_group(
        [4, 2, 3, 4, 10000, 1200000000, 1400000000, 559, 1500000000, 1600000000, 30, 1700000000, 1800000000, 700, 1900000000, 2000000000]);
    is_deeply($extracted,
        [[10000, 1200000000, 1400000000, 559, 1500000000, 1600000000], [30, 1700000000, 1800000000], [700, 1900000000, 2000000000], []], '');
    $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed,
        [4, 2, 3, 4, 10000, 1200000000, 1400000000, 559, 1500000000, 1600000000, 30, 1700000000, 1800000000, 700, 1900000000, 2000000000], '');

    $extracted =
        BOM::CompanyLimits::Limits::_extract_limit_by_group(
        [4, 1, 2, 3, 10000, 1500000000, 1600000000, 559, 1600000000, 1700000000, 30, 1800000000, 1900000000, 700, 1900000000, 2000000000]);
    is_deeply($extracted,
        [[10000, 1500000000, 1600000000], [559, 1600000000, 1700000000], [30, 1800000000, 1900000000], [700, 1900000000, 2000000000]], '');
    $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed,
        [4, 1, 2, 3, 10000, 1500000000, 1600000000, 559, 1600000000, 1700000000, 30, 1800000000, 1900000000, 700, 1900000000, 2000000000], '');

    $extracted =
        BOM::CompanyLimits::Limits::_extract_limit_by_group(
        [4, 4, 4, 4, 10000, 1500000000, 1600000000, 559, 1600000000, 1700000000, 30, 1800000000, 1900000000, 700, 1900000000, 2000000000]);
    is_deeply($extracted,
        [[10000, 1500000000, 1600000000, 559, 1600000000, 1700000000, 30, 1800000000, 1900000000, 700, 1900000000, 2000000000], [], [], []], '');
    $collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply($collapsed,
        [4, 4, 4, 4, 10000, 1500000000, 1600000000, 559, 1600000000, 1700000000, 30, 1800000000, 1900000000, 700, 1900000000, 2000000000], '');

};

my $mock_date_util = Test::MockModule->new('Date::Utility');
subtest 'process_and_get_active_limit', sub {

    $mock_date_util->mock(epoch => sub { return 1600000000; });
    my $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit(
        [30, 1400000000, 1500000000, 40, 1500000000, 1700000000, 60, 1800000000, 1900000000]);
    is_deeply $active_lim,
        {
        amount      => 40,
        start_epoch => 1500000000,
        end_epoch   => 1700000000
        },
        'present limit';
    $mock_date_util->unmock('epoch');

    $mock_date_util->mock(epoch => sub { return 1750000000; });
    $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit(
        [30, 1400000000, 1500000000, 40, 1500000000, 1700000000, 60, 1800000000, 1900000000]);
    is_deeply $active_lim, {amount => "inf"}, 'future limits';
    $mock_date_util->unmock('epoch');

    $mock_date_util->mock(epoch => sub { return 1750000000; });
    $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit(
        [30, 1400000000, 1500000000, 40, 1500000000, 1700000000, 60, 1800000000, 1900000000, 80, 0, 0]);
    is_deeply $active_lim,
        {
        amount      => 80,
        start_epoch => 0,
        end_epoch   => 0
        },
        'indefinite limit';
    $mock_date_util->unmock('epoch');

    $mock_date_util->mock(epoch => sub { return 2000000000; });
    $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit(
        [30, 1400000000, 1500000000, 40, 1500000000, 1700000000, 60, 1800000000, 1900000000]);
    is_deeply $active_lim, undef, 'every limit are past';

    $mock_date_util->mock(epoch => sub { return 2000000000; });
    $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit([]);
    is_deeply $active_lim, undef, 'no limits given';
    $mock_date_util->unmock('epoch');

    $mock_date_util->mock(epoch => sub { return 2000000000; });
    $active_lim = BOM::CompanyLimits::Limits::process_and_get_active_limit();
    is_deeply $active_lim, undef, 'no limits given';
    $mock_date_util->unmock('epoch');
};

subtest 'add_limit and remove_limit', sub {
    # TODO: do a for loop through the whole thing per underlying group
    # TODO: add get_limit test
    # TODO: test get_limit

    _clean_redis();
    my $limit = BOM::CompanyLimits::Limits::add_limit(['POTENTIAL_LOSS', 'frxUSDJPY,,,t', 10000, 1500000000, 1800000000]);
    cmp_ok $limit, 'eq', '1 10000 1500000000 1800000000', '';

    $limit = BOM::CompanyLimits::Limits::add_limit(['POTENTIAL_LOSS', 'frxUSDJPY,,,t', 39, 1500000000, 1800000000]);
    cmp_ok $limit, 'eq', '1 39 1500000000 1800000000 10000 1500000000 1800000000', '';

    $limit = BOM::CompanyLimits::Limits::add_limit(['POTENTIAL_LOSS', 'frxUSDJPY,,,t', 10, 0, 0]);
    cmp_ok $limit, 'eq', '1 10 0 0 39 1500000000 1800000000 10000 1500000000 1800000000', '';

    $limit = BOM::CompanyLimits::Limits::add_limit(['POTENTIAL_LOSS', 'frxUSDJPY,,,t', 30, 1200000000, 1300000000]);
    cmp_ok $limit, 'eq', '1 10 0 0 30 1200000000 1300000000 39 1500000000 1800000000 10000 1500000000 1800000000', '';

    #cmp_ok $limit, 'eq', '', '';
    #
    $mock_date_util->mock(epoch => sub { return 1600000000; });
#$limit = BOM::CompanyLimits::Limits::remove_limit('POTENTIAL_LOSS', 'frxUSDJPY,,,t', 10000, 1500000000, 1800000000);
    #cmp_ok $limit, 'eq', '1 39 1500000000 1800000000', '';
    $mock_date_util->unmock('epoch');

    #$limit = BOM::CompanyLimits::Limits::remove_limit('POTENTIAL_LOSS', 'frxUSDJPY,,,t',10000, 1500000000, 1800000000);
    #cmp_ok $limit, 'eq', '1 39 1500000000 1800000000', 'get_limit returns the correct sequence';

    #$limit = BOM::CompanyLimits::Limits::remove_limit('POTENTIAL_LOSS', 'frxUSDJPY,,,t',39, 1500000000, 1800000000);
    #cmp_ok $limit, 'eq', '1 10000 1500000000 1800000000', 'get_limit returns the correct sequence';

};

subtest 'get_computed_limits', sub {
    # TODO: do a for loop through the whole thing per underlying group
    # TODO: add get_limit test
    # TODO: test get_limit

    _clean_redis();
    my $limit = BOM::CompanyLimits::Limits::add_limit(['POTENTIAL_LOSS', 'frxUSDJPY,,,t', 10000, 1500000000, 1800000000]);
    cmp_ok $limit, 'eq', '1 10000 1500000000 1800000000', '';

    $limit = BOM::CompanyLimits::Limits::add_limit(['POTENTIAL_LOSS', 'frxUSDJPY,,,t', 39, 1500000000, 1800000000]);
    cmp_ok $limit, 'eq', '1 39 1500000000 1800000000 10000 1500000000 1800000000', '';

    $limit = BOM::CompanyLimits::Limits::add_limit(['POTENTIAL_LOSS', 'frxUSDJPY,,,t', 10, 0, 0]);
    cmp_ok $limit, 'eq', '1 10 0 0 39 1500000000 1800000000 10000 1500000000 1800000000', '';

    $limit = BOM::CompanyLimits::Limits::add_limit(['POTENTIAL_LOSS', 'frxUSDJPY,,,t', 30, 1200000000, 1300000000]);
    cmp_ok $limit, 'eq', '1 10 0 0 30 1200000000 1300000000 39 1500000000 1800000000 10000 1500000000 1800000000', '';

    my $computed_lim =
        BOM::CompanyLimits::Limits::get_computed_limits(BOM::Config::RedisReplicated::redis_limits_write->hget('LIMITS', 'frxUSDJPY,,,t'));
    is_deeply($computed_lim, [10, undef, undef, undef], '');

};

done_testing();
