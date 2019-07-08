#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use BOM::Test;
use Test::Exception;
use Data::Dumper;

use Test::MockModule;
use BOM::CompanyLimits::Limits;
use BOM::Config::RedisReplicated;

# TODO: error validations for each function

subtest '_add_limit_value', sub {
    my @limit = BOM::CompanyLimits::Limits::_add_limit_value(10000, 1561801504, 1561801810);
    is_deeply (\@limit, [10000, 1561801504, 1561801810], 'first limit, return itself');

    @limit = BOM::CompanyLimits::Limits::_add_limit_value(10, 0, 0, @limit);
    is_deeply (\@limit, [10, 0, 0, 10000, 1561801504, 1561801810], 'smallest limit, inserted into front');

    @limit = BOM::CompanyLimits::Limits::_add_limit_value(30, 1261801504, 1961801810, @limit);
    is_deeply (\@limit, [10, 0, 0, 30, 1261801504, 1961801810, 10000, 1561801504, 1561801810], 'middle limit');

    @limit = BOM::CompanyLimits::Limits::_add_limit_value(30, 1061801504, 1661801810, @limit);
    is_deeply (\@limit, [10, 0, 0, 30, 1261801504, 1961801810, 30, 1061801504, 1661801810, 10000, 1561801504, 1561801810], 'same limit, position does not matter for this case');

    @limit = BOM::CompanyLimits::Limits::_add_limit_value(20000, 1061801504, 1661801810, @limit);
    is_deeply (\@limit, [10, 0, 0, 30, 1261801504, 1961801810, 30, 1061801504, 1661801810, 10000, 1561801504, 1561801810, 20000, 1061801504, 1661801810], 'same limit, position does not matter for this case');

    @limit = (5, 1261801504, 1961801810);
    @limit = BOM::CompanyLimits::Limits::_add_limit_value(559, 1561801504, 1961801810, @limit);
    is_deeply (\@limit, [5, 1261801504, 1961801810, 559, 1561801504, 1961801810], 'largest limit, insert at the end');
};

subtest '_encode_limit and _decode_limit', sub {
    my $encoded = BOM::CompanyLimits::Limits::_encode_limit(1, 10000, 1561801504, 1561801810);
    my @decoded = BOM::CompanyLimits::Limits::_decode_limit($encoded);
    is_deeply (\@decoded, [1, 10000, 1561801504, 1561801810], 'there is only one type of limit, so no need to specify offset');

    $encoded = BOM::CompanyLimits::Limits::_encode_limit(2, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810);
    @decoded = BOM::CompanyLimits::Limits::_decode_limit($encoded);
    is_deeply (\@decoded, [2, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810], 'there is two type of limit, so need to specify the 1 offset and all the remaining limits');

    $encoded = BOM::CompanyLimits::Limits::_encode_limit(4, 3, 4, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504);
    @decoded = BOM::CompanyLimits::Limits::_decode_limit($encoded);
    is_deeply (\@decoded, [4, 3, 4, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504], 'there is four type of limit, so need to specify the 3 offset and all the remaining limits');
};

subtest '_extract_limit_by_group and _collapse_limit_by_group', sub {
    my $extracted = BOM::CompanyLimits::Limits::_extract_limit_by_group(1, 10000, 1561801504, 1561801810);
    is_deeply ($extracted, {GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP => [10000, 1561801504, 1561801810], GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP_DEFAULTS => undef, GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => undef,GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => undef }, '');
    my @collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply (\@collapsed, [1, 10000, 1561801504, 1561801810], '');

    $extracted = BOM::CompanyLimits::Limits::_extract_limit_by_group(2, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810);
    is_deeply ($extracted, {GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP => [10000, 1561801504, 1561801810, 559, 1561801504, 1961801810], GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP_DEFAULTS => [30, 1261801504, 1961801810], GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => undef,GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => undef }, '');
    @collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply (\@collapsed, [2, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810], '');

    $extracted = BOM::CompanyLimits::Limits::_extract_limit_by_group(4, 3, 4, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504);
    is_deeply ($extracted, {GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP => [10000, 1561801504, 1561801810, 559, 1561801504, 1961801810], GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP_DEFAULTS => [30, 1261801504, 1961801810], GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => undef,GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => undef }, '');
    @collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply (\@collapsed, [4, 3, 4, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504], '');


    $extracted = BOM::CompanyLimits::Limits::_extract_limit_by_group(4, 1, 2, 3, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504);
    is_deeply ($extracted, {GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP => [10000, 1561801504, 1561801810], GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP_DEFAULTS => [559, 1561801504, 1961801810], GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => [30, 1261801504, 1961801810],GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => [700, 1261801504, 2061801504]}, '');
    @collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group(4, 1, 2, 3, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504);
    is_deeply (\@collapsed, [4, 1, 2, 3, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504], '');


    # trick testcase return should be null for everything, as offset goes past the memory block
    $extracted = BOM::CompanyLimits::Limits::_extract_limit_by_group(4, 4, 4, 4, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504);
    is_deeply ($extracted, {GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP => undef, GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP_DEFAULTS => undef, GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => undef,GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS => undef }, '');
    @collapsed = BOM::CompanyLimits::Limits::_collapse_limit_by_group($extracted);
    is_deeply (\@collapsed, [], '');
};

my $mock_redis = Test::MockModule->new('RedisDB');
subtest '_get_encoded_limit', sub {
    $mock_redis->mock(hget => sub { return BOM::CompanyLimits::Limits::_encode_limit(4, 3, 4, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504); });
    my $decoded = BOM::CompanyLimits::Limits::__decode_limit(BOM::CompanyLimits::Limits::_get_encoded_limit('forex,,,t'));
    is_deeply ($decoded, [4, 3, 4, 2, 10000, 1561801504, 1561801810, 559, 1561801504, 1961801810, 30, 1261801504, 1961801810, 700, 1261801504, 2061801504], '');
    $mock_redis->unmock('hget');
};

=pod
subtest 'add_limit and get_limit', sub {
    my ($loss_type, $key, $amount, $start_epoch, $end_epoch) = @_;

    # TODO: do a for loop through the whole thing per underlying group

    #$mock_redis->mock(hget => sub { return undef });
    my $limit = BOM::CompanyLimits::Limits::add_limit('GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP', 'forex,,,t', 10000, 1561801504, 1561801810);
    cmp_ok $limit, 'eq', '10000 1561801504 1561801810', '';
    #$mock_redis->unmock('hget');

    #$mock_redis->mock(hget => sub { return ['10000 1561801504 1561801810'] });
    $limit = BOM::CompanyLimits::Limits::add_limit('GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP', 'forex,,,t', 10, 0, 0);
    cmp_ok $limit, 'eq', '10 0 0 10000 1561801504 1561801810', '';
    #$mock_redis->unmock('hget');

    #$mock_redis->mock(hget => sub { return ['10 0 0 10000 1561801504 1561801810'] });
    $limit = BOM::CompanyLimits::Limits::add_limit('GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP', 'forex,,,t', 30, 1261801504, 1961801810);
    cmp_ok $limit, 'eq', '10 0 0 30 1261801504 1961801810 10000 1561801504 1561801810', '';
    #$mock_redis->unmock('hget');

    #$mock_redis->mock(hget => sub { return ['10 0 0 30 1261801504 1961801810 10000 1561801504 1561801810'] });
    $limit = BOM::CompanyLimits::Limits::add_limit('GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP', 'forex,,,t', 30, 1061801504, 1661801810, $limit);
    cmp_ok $limit, 'eq', '10 0 0 30 1261801504 1961801810 30 1061801504 1661801810 10000 1561801504 1561801810', '';
    #$mock_redis->unmock('hget');


};
=cut
done_testing();
