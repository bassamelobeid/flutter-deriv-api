package BOM::CompanyLimits::Limits;

use strict;
use warnings;

use Data::Dumper;
use Error::Base;

use BOM::Test;
use BOM::Config::RedisReplicated;
use BOM::Database::QuantsConfig;
use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );
use Future::AsyncAwait;

my $redis = BOM::Config::RedisReplicated::redis_limits_write;

use constant CHAR_BYTE   => 1;
use constant SHORT_BYTE  => 2;
use constant LONG_BYTE   => 4;
use constant LIMITS_BYTE => LONG_BYTE * 3;    # amount (signed long), start_epoch (unsigned long), end_epoch (unsigned long)

use constant REDIS_LIMIT_KEY    => 'LIMITS';
use constant COUNTER_PREFIX_KEY => 'COUNTERS_';

# TODO: make every function return a ref to make things consistent
# TODO: Validations, a lot of validations, like a lot a lot of it.
# TODO: Unit test everything

#####################################
## MODULAR FUNCTIONS AND VARIABLES ##
#####################################

# this function should be defined as a modular function for mapping to the underlying !!
my $TYPE_IDX = {
    POTENTIAL_LOSS   => 0,
    POTENTIAL_LOSS_2 => 1,
    REALIZED_LOSS    => 2,
    REALIZEDE_LOSS_2 => 3,
    # ...
    # ...
};

# TODO: temporal part, this will be revisited later
# maps a type to an underlying table in database
sub _db_mapper {
    my $type = shift;
    # this function should be defined as a modular function for mapping to the underlying !!
    my $DB_MAP = {
        # UNDERLYINGGROUP,CONTRACTGROUP,EXPIRYTYPE,ISATM
        POTENTIAL_LOSS => {
            limits   => 'global_potential_loss',
            counters => 'bet.open_contract_aggregates',
        },
        POTENTIAL_LOSS_2 => {
            limits   => 'global_potential_loss',
            counters => 'bet.open_contract_aggregates',
        },
        REALIZED_LOSS => {
            limits   => 'global_potential_loss',
            counters => 'bet.global_aggregates',
        },
        REALIZED_LOSS_2 => {
            limits   => 'global_potential_loss',
            counters => ' bet.global_aggregates',
        },
        # ...
        # ...
    };
    return $DB_MAP->{$type};
}

# maps a type to an underlying index
sub _type_mapper {
    my $type = shift;
    return $TYPE_IDX->{$type};
}

sub _insert_to_db {
    my ($key, $loss_type, $amount) = @_;
    # TODO: need to check what set_global_limits is doing internally, it looks like there are a lot of checks in there
    my ($underlying_grp, $contract_grp, $expiry_type, $is_atm) = split(',', $key);

    # TODO: this should be obtained from redis later not querying the database directly
    my $dbic = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic;
    my $sql = q{
	SELECT symbol, market FROM bet.market WHERE symbol = ?;
    };
    my $bet_market = $dbic->run(fixup => sub { $_->selectrow_hashref($sql, undef, ($underlying_grp)) });

    my $type_idx = _type_mapper($loss_type);
    my $table    = _db_mapper($loss_type);
    my $qc       = BOM::Database::QuantsConfig->new();
    $qc->set_global_limit({
        market            => [$bet_market->{market}],
        underlying_symbol => [($type_idx == 1 || $type_idx == 3) ? undef : $underlying_grp],
        contract_group   => $contract_grp ? [$contract_grp] : undef,
        expiry_type      => $expiry_type  ? [$expiry_type]  : undef,
        barrier_category => $is_atm       ? ['atm']         : undef,
        limit_amount     => $amount,
        limit_type       => $table->{limits},
    });
}

sub _get_counter_from_db {
    my ($loss_type, $key, $now) = @_;

    # TODO: this should be obtained from redis later not querying the database directly
    # TODO: find a better way other than where 1 = 1
    # TODO: query from financial_open_market_bet we're removing open_contracts_aggregates
    my $dbic = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic;
    my $sql = qq{
        SELECT  coalesce(sum(o.payout_price - o.buy_price), 0) as aggregate -- prices in bet.open_contract_aggregates are in USD
        FROM bet.open_contract_aggregates o
        WHERE 1=1
    };

    # special case, as this will mean that it will be an aggregate of everything, so no need to add in filters
    my @conditions = split(',', $key);
    $sql .= " AND symbol = ?"         if $conditions[0];
    $sql .= " AND contract_group = ?" if $conditions[1];
    $sql .= " AND expiry_type = ?"    if $conditions[2];
    $sql .= " AND is_atm = ?"         if $conditions[3];

    my $ret = $dbic->run(fixup => sub { $_->selectrow_hashref($sql, undef, grep($_, @conditions)) });
    return $ret->{aggregate};
}

###########################
## LIMITS IMPLEMENTATION ##
###########################

sub _encode_limit {

    my @input = $_[0]->@*;

    # TODO: Validate encoding format
    my $loss_type  = $input[0];
    my $offset_cnt = $loss_type - 1;

    # the remaining limit counts is minus of loss_type (-1) and count of offsets and divide that by 3 (amount,start,end)
    my $limit_cnt = (scalar @input - 1 - $offset_cnt) / 3;

    # C = the loss_type unsigned integer (1 byte)
    # S = the offset_count unsigned integer (2 byte)
    # l = the amount signed integer (4 byte)
    # L2 = the start_epoch and end_epoch unsgined integer (4 byte)
    # the first param will result in something like CSlL2lL2
    return pack((sprintf('CS%u', $offset_cnt) . "lL2" x $limit_cnt), @input);
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
    return [unpack((sprintf('CS%u', $offsets_cnt) . "lL2" x $limits_cnt), $encoded)];
}

sub _get_key_structure {

    my ($hash) = @_;

    my $key_struct = '';

    # 1. Add in the expiry type (only the first character)
    $key_struct .= $hash->{expiry_type};

    # 1a. If it does not contain binary user id, add the barrier type (only the first character)
    $key_struct .= $hash->{barrier_type} unless $hash->{binary_user_id};

    # 2. Underlying group is always in the middle
    $key_struct .= ',' . $hash->{underlying_symbol} . ',';

    # 3. Append the binary user id/contract group
    $key_struct .= $hash->{binary_user_id} ? $hash->binary_user_id : $hash->{contract_group};

    return $key;
}

# TODO: testcase for this function
sub _remove_limit_value {
    my ($amount, $start_epoch, $end_epoch, $curr_lim) = $_[0]->@*;
    # if curr_lim is undef, this is the first entry
    return unless $curr_lim;
    my @lims;
    # If limit is not added in the loop above, it is the largest limit
    # # and thus belongs to the end of the sequence.
    for (my $i = 0; $i < scalar $curr_lim->@*; $i += 3) {
        my ($i_amount, $i_start_epoch, $i_end_epoch) = @{$curr_lim}[$i .. $i + 2];
        push @lims, $i_amount, $i_start_epoch, $i_end_epoch
            unless ($i_amount == $amount && $i_start_epoch == $start_epoch && $i_end_epoch == $end_epoch);
    }
    return \@lims;
}

sub _add_limit_value {
#warn Dumper(@_);
    my ($amount, $start_epoch, $end_epoch, $curr_lim) = $_[0]->@*;

    # if curr_lim is undef, this is the first entry
    return [$amount, $start_epoch, $end_epoch] unless $curr_lim;

    my @lims;

    # If limit is not added in the loop above, it is the largest limit
    # # and thus belongs to the end of the sequence.
    my $is_added = 0;
    for (my $i = 0; $i < scalar $curr_lim->@*; $i += 3) {
        my ($i_amount, $i_start_epoch, $i_end_epoch) = @{$curr_lim}[$i .. $i + 2];

        # TODO: either throw an error when this happens or we just return the original one
        return $curr_lim if ($i_amount == $amount && $i_start_epoch == $start_epoch && $i_end_epoch == $end_epoch);

        if ($amount < $i_amount and $is_added == 0) {
            push(@lims, $amount, $start_epoch, $end_epoch);
            $is_added = 1;
        }
        push @lims, $i_amount, $i_start_epoch, $i_end_epoch;
    }
    push(@lims, $amount, $start_epoch, $end_epoch) unless $is_added;
    #warn "dumping .. \n";
    #warn Dumper(@lims);
    return \@lims;
}

# helper function, returns undef if from or to indexes are out of range
sub _array_slice {
    my ($from, $to, @arr) = @_;
    return (($from < 0 || $to >= scalar @arr) ? [] : [@arr[$from .. $to]]);
}

sub _extract_limit_by_group {
    my @inputs = $_[0]->@*;

    # TODO: test edge cases
    my $loss_type  = $inputs[0];
    my $offset_cnt = $loss_type - 1;
    # get offsets and limits portion
    my $offsets = _array_slice(1, $offset_cnt, @inputs);
    my $limits = _array_slice($offset_cnt + 1, $#inputs, @inputs);

    my $extracted_limits = [];
    foreach my $idx (0 .. $offset_cnt) {
        my $from;
        my $to;
        if ($offsets) {
            $from = ($idx - 1 < 0) ? 0 : $offsets->[$idx - 1] * 3;
            $to = ($offsets->[$idx]) ? ($offsets->[$idx] * 3) - 1 : scalar $limits->@* - 1;
        } else {
            # when there are no offsets
            $from = 0;
            $to   = scalar $limits->@* - 1;
        }

        push $extracted_limits->@*, _array_slice($from, $to, $limits->@*);
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
    $limits_cnt += scalar @{$_} foreach $expanded_limits->@*;
    $limits_cnt /= 3;

    my $type_cnt = scalar $expanded_limits->@*;
    foreach my $idx (0 .. $type_cnt - 1) {

        my @curr_lim = @{$expanded_limits->[$idx]};
        push @limits, @curr_lim;

        if ($idx and scalar @curr_lim != 0) {
            push(@offsets, (scalar @limits / 3) - 1);
        } elsif (scalar @curr_lim == 0) {
            # push limits to offsets only if the idx is 0
            # push the size of all limits and + 1 to overflow the offset (indicating that limit is not yet set) if current limit is empty
            push(@offsets, $limits_cnt);
        }
    }

    return [$type_cnt, @offsets, @limits];
}

sub _set_counters {
    my ($loss_type, $key, $now) = @_;
    my $counter_key = COUNTER_PREFIX_KEY . $loss_type;
    my $is_set = $redis->hget($counter_key, $key);
    $redis->hincrbyfloat($counter_key, $key, _get_counter_from_db($loss_type, $key, $now)) unless ($is_set);
}

sub _get_new_limit {
    # TODO: get current limit and figure out the new limits
    # TODO: still deciding how this will be done
    return 1;
}

# input: encoded stuff
# decode > [1000, undef, undef, undef]

=pod
        POTENTIAL_LOSS   => 0,
        POTENTIAL_LOSS_2 => 1,
        REALIZED_LOSS    => 2,
        REALIZEDE_LOSS_2 => 3,
=cut

sub get_active_limits {
    # takes in encoded stuff
    my $encoded = shift;
    return unless $encoded;

    # there is already an existing entry
    my $decoded_limits = _decode_limit($encoded);
    my $expanded_arr   = _extract_limit_by_group($decoded_limits);
    my $computed_lims;
    foreach my $idx (values %{$TYPE_IDX}) {
        my $active_lim = process_and_get_active_limit($expanded_arr->[$idx]);
        $computed_lims->[$idx] = ($active_lim->{amount}) ? $active_lim->{amount} : undef;
    }
    return $computed_lims;
}

# TODO: verify if this function works
sub remove_limit {
    my ($loss_type, $key, $amount, $start_epoch, $end_epoch) = $_[0]->@*;

    my $encoded = $redis->hget(REDIS_LIMIT_KEY, $key);
    return unless $encoded;

    my $underlying_idx = _type_mapper($loss_type);

    # there is already an existing entry
    my $decoded_limits = _decode_limit($encoded);
    my $expanded_arr   = _extract_limit_by_group($decoded_limits);
    $expanded_arr->[$underlying_idx] = _remove_limit_value($amount, $start_epoch, $end_epoch, $expanded_arr->[$underlying_idx]);

    # get limit that is currently active
    my $active_lim = process_and_get_active_limit($expanded_arr);

    my $redis_w     = $redis;
    my $counter_key = "COUNTERS_$loss_type";

    # there are still limits left
    return $redis_w->hset(REDIS_LIMIT_KEY, $key, $active_lim->{amount}) if $active_lim->{amount};

    $redis_w->watch(REDIS_LIMIT_KEY);
    $redis_w->watch($counter_key);
    $redis_w->multi;
    $redis_w->hdel(REDIS_LIMIT_KEY, $key);
    $redis_w->hdel($counter_key,    $key);
    return $redis_w->exec();

}

sub process_and_get_active_limit {
    my $limits = shift;
    return unless $limits;

    my $chosen_limit;
    my $has_future_limit;
    my $now = Date::Utility->new()->epoch();

    for (my $i = 0; $i < scalar $limits->@*; $i += 3) {
        my ($i_amount, $i_start_epoch, $i_end_epoch) = @{$limits}[$i .. $i + 2];

        # indefinite limit OR active limit
        if (   ($i_start_epoch == 0 && $i_end_epoch == 0)
            || ($now >= $i_start_epoch && $now < $i_end_epoch))
        {
            $chosen_limit = {
                amount      => $i_amount,
                start_epoch => $i_start_epoch,
                end_epoch   => $i_end_epoch,
            };
            last;
        }
        # expired limit
        next if ($i_end_epoch <= $now);
        # future limit
        $has_future_limit = 1 if ($i_start_epoch > $now);
    }
    return ($has_future_limit && !$chosen_limit) ? {amount => "inf"} : $chosen_limit;
}

# TODO: need to verify this function will work as a single transaction
sub add_limit {
    my ($loss_type, $hash, $amount, $start_epoch, $end_epoch) = @_;

    my $key = _get_key_structure($hash);

    # check if redis has been added successfully
    my $now = Date::Utility->new();

    my $encoded = $redis->hget(REDIS_LIMIT_KEY, $key);
    my $underlying_idx = _type_mapper($loss_type);
    my $expanded_arr;

    if ($encoded) {
        # there is already an existing entry
        my $decoded_limits = _decode_limit($encoded);
        $expanded_arr = _extract_limit_by_group($decoded_limits);
        $expanded_arr->[$underlying_idx] = _add_limit_value([$amount, $start_epoch, $end_epoch, $expanded_arr->[$underlying_idx]]);
    } else {
        # new entry
        $expanded_arr->[$_] = [] foreach (0 .. $underlying_idx);
        $expanded_arr->[$underlying_idx] = _add_limit_value([$amount, $start_epoch, $end_epoch]);
    }

    my $collapsed_limits = _collapse_limit_by_group($expanded_arr);
    my $encoded_limits   = _encode_limit($collapsed_limits);

    $redis->hset(REDIS_LIMIT_KEY, $key, $encoded_limits);
    _insert_to_db($key, $loss_type, $amount);
    _set_counters($loss_type, $key, $now);

    return join(' ', @{$collapsed_limits});
}

async sub query_limits {
    my ($underlying, $combinations) = @_;
    my $limits_response = $redis->hmget('LIMITS', @$combinations);
    my %limits;
    foreach my $i (0 .. $#$combinations) {
        if ($limits_response->[$i]) {
            $limits{$combinations->[$i]} = get_active_limits($limits_response->[$i]);
        }
    }

    return compute_limits(\%limits, $underlying);
}

sub compute_limits {
    my ($limits, $underlying) = @_;
    my %totals;

    # The loop here makes the assumption that underlying group limits
    # all procede underlying limits.
    while (my ($k, $v) = each %{$limits}) {
        # for each array ref, allocate exactly 2 elements in order: potential,
        # realized loss
        # Potential #1 and Realized #1 are the actual limits for the totals
        $totals{$k} = [$v->[0], $v->[2]];

        _handle_underlying_group_defaults(\%totals, $underlying, $k, $v, 1, 0);
        _handle_underlying_group_defaults(\%totals, $underlying, $k, $v, 3, 2);
    }

    return \%totals;
}

sub _handle_underlying_group_defaults {
    my ($totals, $underlying, $k, $v, $group_default_idx, $target_idx) = @_;

    if ($v->[$group_default_idx]) {
        my $loss_limit_2 = $v->[$group_default_idx];
        if ($k =~ /(,.*)/) {    # trim off underlying group from key
            my $underlying_key = "$underlying$1";
            my $underlying_val = $totals->{$underlying_key};
            if ($underlying_val) {
                my $loss_limit = $underlying_val->[$target_idx];
                if ($loss_limit) {
                    $underlying_val->[$target_idx] = min($loss_limit, $loss_limit_2);
                } else {
                    $underlying_val->[$target_idx] = $loss_limit_2;
                }
            } else {
                # Create array ref using the magic of auto vivification
                $totals->{$underlying_key}->[$target_idx] = $loss_limit_2;
            }
        }
    }
}
1;
