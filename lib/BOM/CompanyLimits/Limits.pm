package BOM::CompanyLimits::Limits;

use strict;
use warnings;

use Data::Dumper;
use Error::Base;

use BOM::Test;
use BOM::Config::RedisReplicated;
use BOM::Database::QuantsConfig;
use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );

use constant CHAR_BYTE   => 1;
use constant SHORT_BYTE  => 2;
use constant LONG_BYTE   => 4;
use constant LIMITS_BYTE => LONG_BYTE * 3;    # amount (signed long), start_epoch (unsigned long), end_epoch (unsigned long)

use constant REDIS_LIMIT_KEY    => 'LIMITS';
use constant COUNTER_PREFIX_KEY => 'COUNTERS_';

# TODO: make every function return a ref to make things consistent
# TODO: Validations, a lot of validations, like a lot a lot of it.
# TODO: Unit test everything

#######################
## MODULAR FUNCTIONS ##
#######################

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
    # this function should be defined as a modular function for mapping to the underlying !!
    my $TYPE_IDX = {
        # UNDERLYINGGROUP,CONTRACTGROUP,EXPIRYTYPE,ISATM
        POTENTIAL_LOSS   => 0,
        POTENTIAL_LOSS_2 => 1,
        REALIZED_LOSS    => 2,
        REALIZEDE_LOSS_2 => 3,
        # ...
        # ...
    };
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
    return [unpack((sprintf('CS%u', $offsets_cnt) . "lL2" x $limits_cnt), $encoded)];
}

sub _add_limit_value {
    my ($amount, $start_epoch, $end_epoch, $curr_lim) = @_;

    # if curr_lim is undef, this is the first entry
    return \@_ unless $curr_lim;

    my @lims;

    # If limit is not added in the loop above, it is the largest limit
    # # and thus belongs to the end of the sequence.
    my $is_added = 0;
    for (my $i = 0; $i < scalar $curr_lim->@*; $i += 3) {
        my ($i_amount, $i_start_epoch, $i_end_epoch) = @{$curr_lim}[$i .. $i + 2];

        if ($amount < $i_amount and $is_added == 0) {
            push(@lims, $amount, $start_epoch, $end_epoch);
            $is_added = 1;
        }
        push @lims, $i_amount, $i_start_epoch, $i_end_epoch;
    }
    push(@lims, $amount, $start_epoch, $end_epoch) unless $is_added;
    return \@lims;
}

# helper function, returns undef if from or to indexes are out of range
sub _array_slice {
    my ($from, $to, @arr) = @_;
    return (($from < 0 || $to >= scalar @arr) ? [] : [@arr[$from .. $to]]);
}

sub _extract_limit_by_group {
    # TODO: test edge cases
    my $loss_type  = $_[0];
    my $offset_cnt = $loss_type - 1;
    # get offsets and limits portion
    my $offsets = _array_slice(1, $offset_cnt, @_);
    my $limits = _array_slice($offset_cnt + 1, $#_, @_);

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

sub _get_decoded_limit {
    my $key = shift;
    return _decode_limit(BOM::Config::RedisReplicated::redis_limits_write->hget(REDIS_LIMIT_KEY, $key));
}

sub get_limit {
    # TODO: Expected input 'GLOBAL_REALIZED_LOSS_UNDERLYINGGROUP', 'forex,,,t'
    # TODO: Expected output '10 0 0 10000 1561801504 1561801810"
    my ($loss_type, $key) = @_;
    my $decoded_limits  = _get_decoded_limit($key);
    my $expanded_struct = _extract_limit_by_group(@{$decoded_limits});
    return join(' ', @{$expanded_struct->{$loss_type}});
}

sub _set_counters {
    my ($loss_type, $key, $now) = @_;
    my $counter_key = COUNTER_PREFIX_KEY . $loss_type;
    my $is_set = BOM::Config::RedisReplicated::redis_limits_write->hget($counter_key, $key);
    BOM::Config::RedisReplicated::redis_limits_write->hincrbyfloat($counter_key, $key, _get_counter_from_db($loss_type, $key, $now)) unless ($is_set);
}

sub process_and_get_active_limit {
    my $limits = shift;

    my $chosen_limit;
    my $has_future_limit;
    my $now = Date::Utility->new()->epoch();

    for (my $i = 0; $i < scalar $limits->@*; $i += 3) {
        my ($i_amount, $i_start_epoch, $i_end_epoch) = @{$limits}[$i .. $i + 2];

        # indefinite limit OR active limit
        if (   ($i_start_epoch == 0 && $i_end_epoch == 0)
            || ($now >= $i_start_epoch && $now < $i_end_epoch))
        {
            $chosen_limit = $i_amount;
            last;
        }
        # expired limit
        next if ($i_end_epoch <= $now);
        # future limit
        $has_future_limit = 1 if ($i_start_epoch > $now);
    }
    return ($has_future_limit && !$chosen_limit) ? "inf" : $chosen_limit;
}

# TODO: need to verify this function will work as a single transaction
sub add_limit {
    my ($loss_type, $key, $amount, $start_epoch, $end_epoch) = @_;
    # check if redis has been added successfully
    my $now = Date::Utility->new();

    my $decoded_limits = _get_decoded_limit($key);
    my $expanded_arr   = _extract_limit_by_group(@{$decoded_limits});

    #warn Dumper($loss_type);
    my $underlying_idx = _type_mapper($loss_type);
    #warn Dumper($underlying_idx);
    $expanded_arr->[$underlying_idx] = _add_limit_value($amount, $start_epoch, $end_epoch, $expanded_arr->[$underlying_idx]);

    my $collapsed_limits = _collapse_limit_by_group($expanded_arr);
    my $encoded_limits   = _encode_limit(@{$collapsed_limits});

    BOM::Config::RedisReplicated::redis_limits_write->hset(REDIS_LIMIT_KEY, $key, $encoded_limits);
    _insert_to_db($key, $loss_type, $amount);
    _set_counters($loss_type, $key, $now);

    return join(' ', @{$collapsed_limits});
}

1;
