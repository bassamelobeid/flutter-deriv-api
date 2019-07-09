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
    0 => 'GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP',
    1 => 'GLOBAL_POTENTIAL_LOSS_UNDERLYINGGROUP_DEFAULTS',
    2 => 'GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP',
    3 => 'GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP_DEFAULTS',
};

sub _encode_limit {
    # TODO: Validate encoding format
    my $loss_type  = $_[0];
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

# helper function, returns undef if from or to indexes are out of range
sub _array_slice {
    my ($from, $to, @arr) = @_;
    return ($from < 0 || $to >= scalar @arr) ? () : @arr[$from .. $to];
}

sub _extract_limit_by_group {
    # TODO: test edge cases
    my $loss_type  = $_[0];
    my $offset_cnt = $loss_type - 1;
    # get offsets and limits portion
    my @offsets = _array_slice(1, $offset_cnt, @_);
    my @limits = _array_slice($offset_cnt + 1, $#_, @_);

    my $extracted_limits;
    foreach my $idx (0 .. $offset_cnt) {
        my $from;
        my $to;

        if (scalar @offsets) {
            $from = ($idx - 1 < 0) ? 0 : $offsets[$idx - 1] * 3;
            $to = ($offsets[$idx]) ? ($offsets[$idx] * 3) - 1 : $#limits;
        } else {
            # when there are no offsets
            $from = 0;
            $to   = $#limits;
        }

        $extracted_limits->{$LOSS_TYPE_MAP->{$idx}} = [_array_slice($from, $to, @limits)];
    }
    return $extracted_limits;
}

sub _collapse_limit_by_group {
    # TODO: test edge cases
    my $expanded_limits = shift;
    my @offsets;
    my @limits;

    # get number of limits there are in the struct
    my $limits_cnt = 0;
    $limits_cnt += scalar @{$_} foreach values %{$expanded_limits};
    $limits_cnt /= 3;

    my $type_cnt = scalar keys %{$expanded_limits};
    foreach my $idx (0 .. $type_cnt - 1) {

        my @curr_lim = @{$expanded_limits->{$LOSS_TYPE_MAP->{$idx}}};
        push @limits, @curr_lim;

        if ($idx and scalar @curr_lim != 0) {
            push(@offsets, (scalar @limits / 3) - 1);
        } elsif (scalar @curr_lim == 0) {
            # push limits to offsets only if the idx is 0
            # push the size of all limits and + 1 to overflow the offset (indicating that limit is not yet set) if current limit is empty
            push(@offsets, $limits_cnt);
        }
    }

    return ($type_cnt, @offsets, @limits);
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
