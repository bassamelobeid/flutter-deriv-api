package BOM::CompanyLimits::Check;

use strict;
use warnings;

use BOM::CompanyLimits::Helpers qw(get_redis);

my $loss_map_to_idx = {
    'potential_loss' => 0,
    'realized_loss'  => 1,
    'turnover'       => 2,
    'payout'         => 3,
};

sub check_realized_loss {
    my ($landing_company, $limit_settings, $combinations) = @_;

    my $redis = get_redis($landing_company, 'realized_loss');
    my $response = $redis->hmget("$landing_company:realized_loss", @$combinations);

    return _check_loss_type_breaches($response, $limit_settings, $combinations, 'realized_loss');
}

sub check_potential_loss {
    my ($limit_settings, $combinations, $potential_loss_incr_response) = @_;

    return _check_loss_type_breaches($potential_loss_incr_response, $limit_settings, $combinations, 'potential_loss');
}

# For turnover, because it is only underlying specific, these are the only increments
# we make (note that barrier_type is removed only for turnover):
#
#     Turnover Increments
#  idx | exp | u | contract |
# -----+-----+---+----------+
#   0  |  e  | u |    c     |
#   1  |  e  | u |    +     |
#   2  |  +  | u |    c     |
#   3  |  +  | u |    +     |
#
# Because turnover is inferred to be binary user specific, these 4 increment values
# is then used to check 8 limit settings (remember that for global limits, '*' is
# expanded in limits.get_company_limits):
#
#           All Limit Definitions       | Turnover|
# -----+-----+---------+-----+----------+   Idx   |
#  idx | exp | barrier | u/g | contract |         |
# -----+-----+---------+-----+----------+---------+
#   0  |  e  |    b    |  u  |     c    |         |
#   1  |  e  |    b    |  u  |     +    |         |
#   2  |  e  |    b    |  g  |     c    |         |
#   3  |  e  |    b    |  g  |     +    |         |
#   4  |  e  |    b    |  +  |     c    |         |
#   5  |  e  |    b    |  +  |     +    |         |
#   6  |  e  |    +    |  u  |     c    |    0    |
#   7  |  e  |    +    |  u  |     +    |    1    |
#   8  |  e  |    +    |  g  |     c    |         |
#   9  |  e  |    +    |  g  |     +    |         |
#   10 |  e  |    +    |  +  |     c    |         |
#   11 |  e  |    +    |  +  |     +    |         |
#   12 |  +  |    b    |  u  |     c    |         |
#   13 |  +  |    b    |  u  |     +    |         |
#   14 |  +  |    b    |  g  |     c    |         |
#   15 |  +  |    b    |  g  |     +    |         |
#   16 |  +  |    b    |  +  |     c    |         |
#   17 |  +  |    b    |  +  |     +    |         |
#   18 |  +  |    +    |  u  |     c    |    2    |
#   19 |  +  |    +    |  u  |     +    |    3    |
#   20 |  +  |    +    |  g  |     c    |         |
#   21 |  +  |    +    |  g  |     +    |         |
#   22 |  +  |    +    |  +  |     c    |         |
#   23 |  +  |    +    |  +  |     +    |         |
# ------------>> User Specific Limits <<----------+
#   24 |  e  |         |  g  |          |    1    |
#   25 |  e  |         |  +  |          |    1    |
#   26 |  +  |         |  g  |          |    3    |
#   27 |  +  |         |  +  |          |    3    |
sub check_turnover {
    my ($limit_settings, $combinations, $turnover_incr_response) = @_;

    my @response;
    @response[6, 7, 18, 19, 24 .. 27] = @{$turnover_incr_response}[0 .. 3, 1, 1, 3, 3];

    return _check_loss_type_breaches(\@response, $limit_settings, $combinations, 'turnover');
}

sub process_breaches {
    my ($breaches, $contract) = @_;

    if (@$breaches) {
        foreach my $breach (@$breaches) {
            # TODO: publish breach should be an event. Do not block buys while sending emails
            # publish_breach($breach, $contract);

            # Only block trades for actual breaches; ignore threshold warnings
            if ($breach->[3] > $breach->[2]) {
                # For now, we simply mimic database errors instead creating new error codes.
                if (   $breach->[0] eq 'potential_loss'
                    or $breach->[0] eq 'realized_loss')
                {
                    die ['BI051'];
                } elsif ($breach->[0] eq 'turnover') {
                    die ['BI011'];
                }
                die "Unknown Limit Breach @$breach";
            }
        }
    }
}

sub publish_breach {
    my ($breach, $contract) = @_;
    my $msg = _build_breach_msg($breach, $contract);

    # TODO: this looks like in the wrong place. We keep as is for legacy reasons.
    #       Ideally publishing trade warnings should be a part of trade limits code
    # NOTE: 1st param here is Redis instance, which is not used (lol)
    BOM::Platform::Script::TradeWarnings::_publish(undef, $msg);

    return;
}

# TODO: Threshold is currently hardcoded, but we will store as a Redis key later
my $threshold = 0.5;

sub _check_loss_type_breaches {
    my ($response, $limit_settings, $combinations, $loss_type) = @_;

    my @breaches;

    my $get_limit_check_attributes = sub {
        my ($i) = @_;

        my $comb = $combinations->[$i];
        return () unless $comb;

        my $limit = $limit_settings->{$comb};
        return () unless $limit;

        my $loss_type_limit = $limit->[$loss_map_to_idx->{$loss_type}];
        return () unless $loss_type_limit ne '';

        my $curr_amount = $response->[$i];
        return () unless defined $curr_amount;

        return ($comb, $limit, $loss_type_limit, $curr_amount);
    };

    # Global limits
    foreach my $i (0 .. 23) {
        my @attr = $get_limit_check_attributes->($i);
        next unless @attr;
        my ($comb, $limit, $loss_type_limit, $curr_amount) = @attr;

        my $diff = $curr_amount - $loss_type_limit;
        if ($diff > 0
            or ($threshold and $curr_amount > ($loss_type_limit * $threshold)))
        {
            push(@breaches, [$loss_type, $comb, $loss_type_limit, $curr_amount]);
        }
    }

    # User specific limits
    # Alert threshold not available for user specific limits; it is never used
    foreach my $i (24 .. 27) {
        my @attr = $get_limit_check_attributes->($i);
        next unless @attr;
        my ($comb, $limit, $loss_type_limit, $curr_amount) = @attr;

        if ($curr_amount > $loss_type_limit) {
            push(@breaches, [$loss_type, $comb, $loss_type_limit, $curr_amount]);
        }
    }

    return @breaches;
}

my $expiry_map = {
    t => 'tick',
    d => 'daily',
    i => 'intraday',
    u => 'ultrashort',
};

my $barrier_map = {
    a => 'atm',
    n => 'non-atm',
};

sub _build_breach_msg {
    my ($breach, $contract) = @_;
    my ($loss_type, $comb, $loss_type_limit, $curr_amount) = @$breach;
    my $account_data = $contract->{account_data};

    my @attrs = split(/,/, $comb);
    my ($type, $rank);

    $rank->{expiry_type} = $expiry_map->{substr($attrs[0], 0, 1)};
    $rank->{market_or_symbol} = $attrs[1];

    # Only user specific limits have 1 char as 1st attribute in key
    if (length($attrs[0]) == 1) {
        # User specific limits
        $type = "user_$loss_type";
    } else {
        # Global limits
        $type = "global_$loss_type";
        $rank->{contract_group} = $attrs[2];
        $rank->{barrier_type} = $barrier_map->{substr($attrs[1], 1, 1)};
    }

    my $msg = {
        rank            => $rank,
        current_amount  => $curr_amount,
        limit_amount    => $loss_type_limit,
        type            => $type,
        client_loginid  => $account_data->{client_loginid},
        binary_user_id  => $account_data->{binary_user_id},
        landing_company => $account_data->{landing_company},
    };

    return $msg;
}

1;

