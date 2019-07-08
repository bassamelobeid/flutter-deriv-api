package BOM::CompanyLimits::Limits;

use strict;
use warnings;

use Data::Dumper;
use Error::Base;
use BOM::Test;
use BOM::Config::RedisReplicated;

use constant CHAR_BYTE   => 1;
use constant SHORT_BYTE  => 2;
use constant LONG_BYTE   => 4;
use constant LIMITS_BYTE => LONG_BYTE * 3;    # amount (signed long), start_epoch (unsigned long), end_epoch (unsigned long)

# TODO: Validations, a lot of validations, like a lot a lot of it.
# TODO: Unit test everything

# map underlying to binary form in redis storage
my $LOSS_TYPE_MAP = {
    GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP          => 0,
    GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP_DEFAULTS => 1,
    GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP           => 2,
    GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS  => 3,
};

sub _encode_limit {
    # TODO: Validate encoding format
    my $loss_type = $_[0];
    # number of offset is loss_type - 1
    my $offset_cnt = $loss_type - 1;
    # the remaining limit counts is minus of loss_type (-1) and count of offsets and divide that by 3 (amount,start,end)
    my $limit_cnt = (scalar @_ - 1 - $offset_cnt) / 3;
    # C = the loss_type unsigned integer (1 byte)
    # S = the offset_count unsigned integer (2 byte)
    # l = the amount signed integer (4 byte)
    # L2 = the start_epoch and end_epoch unsgined integer (4 byte)
    # the first param will result in something like CSlL2lL2
    return pack((sprintf('CS%u', $offset_cnt) . "lL2" x $limit_cnt), @_);
}

sub _decode_limit {
    my $encoded = shift;
    # TODO: Validate decoding format
    my ($loss_type) = unpack('C', $encoded);
    # number of offset is loss_type - 1
    my $offsets_cnt = $loss_type - 1;
    # the remaining limit counts is minus of loss_type (-1) and count of offsets
    my $limits_cnt = (length($encoded) - CHAR_BYTE - (SHORT_BYTE * $offsets_cnt)) / LIMITS_BYTE;
    # C = the loss_type unsigned integer (1 byte)
    # S = the offset_count unsigned integer (2 byte)
    # l = the amount signed integer (4 byte)
    # L2 = the start_epoch and end_epoch unsgined integer (4 byte)
    # the first param will result in something like CSlL2lL2
    return unpack((sprintf('CS%u', $offsets_cnt) . "lL2" x $limits_cnt), $encoded);
}

sub _add_limit_value {
    my ($amount, $start_epoch, $end_epoch, @curr_lim) = @_;

    # curr_lim is not yet initialized or key not found in redis
    return @_ unless @curr_lim;

    my @lims;

    # variable needed for if the new amount is the largest than all existing limits
    my $is_added;
    for (my $i = 0; $i < $#curr_lim; $i += 3) {
        my $a = $curr_lim[$i];
        my $s = $curr_lim[$i + 1];
        my $e = $curr_lim[$i + 2];
        if ($amount < $a) {
            push(@lims, $amount, $start_epoch, $end_epoch);
            $is_added = 1;
        }
        push @lims, $a, $s, $e;
    }
    push(@lims, $amount, $start_epoch, $end_epoch) unless $is_added;
    return @lims;
}

sub _extract_limit_by_group {
    # TODO: Expected input (4 3 4 4 300000 1561801504 1561801810 500000 0 0 800000 1561801504 1561801810 1000000 0 0)
    # TODO: Expected output { "GLOBAL_POTENTIAL_LOSS_UNDERLYING" => ..., "GLOBAL_POTENTIAL_LOSS_UNDERLYING_DEFAULT" => ..., .... }
}

sub _collapse_limit_by_group {
    # TODO: Expected input { "GLOBAL_POTENTIAL_LOSS_UNDERLYING" => ..., "GLOBAL_POTENTIAL_LOSS_UNDERLYING_DEFAULT" => ..., .... }
    # TODO: Expected output (4 3 4 4 300000 1561801504 1561801810 500000 0 0 800000 1561801504 1561801810 1000000 0 0)
}

sub _get_encoded_limit {
    # TODO: Expected input 'forex,,,t'
    # TODO: Expected output encoded limits
}

sub get_limit {
    # TODO: Expected input 'GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP', 'forex,,,t'
    # TODO: Expected output '10 0 0 10000 1561801504 1561801810"
#my $lim = BOM::Config::RedisReplicated::redis_limits_write->hmget($loss_type, $key);
}

sub add_limit {
    my ($loss_type, $key, $amount, $start_epoch, $end_epoch) = @_;

    # _get_encoded_limit ($key)
    # _extract_limit_by_group($encoded_limits)
    # _add_limits_value($limits.....)
    # _collapse_limits_by_group($hash_struct_to_be_collapsed)
    # _encode_limit($string to be encoded);
    # store_to_redis

    # TODO: Insert into database
}

1;
