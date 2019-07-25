package BOM::CompanyLimits;
use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use Date::Utility;
use Data::Dumper;
use BOM::CompanyLimits::Helpers;
use BOM::CompanyLimits::Limits;
use ExchangeRates::CurrencyConverter qw(convert_currency);

=head1 NAME


=cut

use constant {
    POTENTIAL_LOSS_TOTALS => 0,
    REALIZED_LOSS_TOTALS  => 1,
};

my $redis = BOM::Config::RedisReplicated::redis_limits_write;

sub set_underlying_groups {
    # POC, we should see which broker code to use
    my $dbic = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic;

    my $sql = q{
	SELECT symbol, market FROM bet.market;
    };
    my $bet_market = $dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef) });

    my @symbol_underlying;
    push @symbol_underlying, @$_ foreach (@$bet_market);
    $redis->hmset('UNDERLYINGGROUPS', @symbol_underlying);
}

sub set_contract_groups {
    # POC, we should see which broker code to use
    my $dbic = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic;

    my $sql = q{
	SELECT bet_type, contract_group FROM bet.contract_group;
    };
    my $bet_grp = $dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef) });

    my @contract_grp;
    push @contract_grp, @$_ foreach (@$bet_grp);
    $redis->hmset('CONTRACTGROUPS', @contract_grp);
}

sub add_buy_contract {
    my ($contract) = @_;
    my ($bet_data, $account_data) = @$contract{qw/bet_data account_data/};

    my $underlying = $bet_data->{underlying_symbol};
    my ($contract_group, $underlying_group) = _get_attr_groups($bet_data);

    # print 'BET DATA: ', Dumper($contract);
    my @combinations = _get_combinations($contract, $underlying_group, $contract_group);
    my %limits = _query_limits($underlying, \@combinations);

    my @realized_loss_request;
    while (my ($k, $v) = each %limits) {
        push(@realized_loss_request, $k) if ($v->[REALIZED_LOSS_TOTALS]);
    }

    my $potential_loss = _convert_to_usd($account_data, $bet_data->{payout_price} - $bet_data->{buy_price});

    # Realized loss (selected depending on whether we need to use it) and incrementing totals
    # for potential loss is done in a single transaction (via multi exec) and single redis call (via pipelinening)
    my (@realized_loss_response, @potential_loss_response);
    $redis->multi(sub { });
    if (@realized_loss_request) {
        $redis->send_command(('HMGET', 'TOTALS_REALIZED_LOSS', @realized_loss_request), sub { });
    }
    foreach my $p (@combinations) {
        $redis->hincrbyfloat('TOTALS_POTENTIAL_LOSS', $p, $potential_loss, sub { });
    }
    $redis->exec(
        sub {
            my $response = $_[1];
            my $i = 0;
            if (@realized_loss_request) {
                @realized_loss_response = @{$response}[$i .. $i + $#realized_loss_request];
                $i += $#realized_loss_request;
            }
            @potential_loss_response = @{$response}[$i .. $i + $#combinations];
        });
    $redis->mainloop;

    my %totals;
    foreach my $i (0 .. $#combinations) {
        if ($limits{$combinations[$i]}->[POTENTIAL_LOSS_TOTALS]) {
            $totals{$combinations[$i]}->[POTENTIAL_LOSS_TOTALS] = $potential_loss_response[$i];
        }
    }
    foreach my $i (0 .. $#realized_loss_request) {
        $totals{$realized_loss_request[$i]}->[REALIZED_LOSS_TOTALS] = ($realized_loss_response[$i] // 0);
    }

    print 'TOTALS:', Dumper(\%totals);
}

sub add_sell_contract {
    my ($contract)   = @_;
    my $bet_data     = $contract->{bet_data};
    my $account_data = $contract->{account_data};
    # print 'BET DATA: ', Dumper($contract);

    my ($contract_group, $underlying_group) = _get_attr_groups($bet_data);

    my @combinations = _get_combinations($contract, $underlying_group, $contract_group);

    # For sell, we increment totals but do not check if they exceed limits;
    # we only block buys, not sells.
    my $realized_loss = _convert_to_usd($account_data, $bet_data->{sell_price} - $bet_data->{buy_price});

    # On sells, we increment realized loss and deduct realized loss from potential loss
    $redis->multi(sub { });
    foreach my $p (@combinations) {
        # Since no checks are done, we simply increment and discard the response
        $redis->hincrbyfloat('TOTALS_REALIZED_LOSS',  $p, $realized_loss,  sub { });
        $redis->hincrbyfloat('TOTALS_POTENTIAL_LOSS', $p, -$realized_loss, sub { });
    }
    $redis->exec(sub { });
    $redis->mainloop;
}

sub _query_limits {
    my ($underlying, $combinations) = @_;
    my $limits_response = $redis->hmget('LIMITS', @$combinations);
    my %limits;
    foreach my $i (0 .. $#$combinations) {
        if ($limits_response->[$i]) {
            $limits{$combinations->[$i]} = BOM::CompanyLimits::Limits::get_active_limits($limits_response->[$i]);
        }
    }
    # print 'ACTIVE LIMITS:', Dumper(\%limits);
    return compute_limits(\%limits, $underlying);
}

sub _get_attr_groups {
    my ($bet_data) = @_;

    my ($contract_group, $underlying_group);
    $redis->hget(
        'CONTRACTGROUPS',
        $bet_data->{bet_type},
        sub {
            $contract_group = $_[1];
        });
    $redis->hget(
        'UNDERLYINGGROUPS',
        $bet_data->{underlying_symbol},
        sub {
            $underlying_group = $_[1];
        });
    $redis->mainloop;

    return ($contract_group, $underlying_group);
}

sub _convert_to_usd {
    my ($account_data, $amount) = @_;

    if ($account_data->{currency_code} ne 'USD') {
        $amount = convert_currency($amount, $account_data->{currency_code}, 'USD');
    }

    return $amount;
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

    return %totals;
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

sub _get_combinations {
    my ($contract, $underlying_group, $contract_group) = @_;
    my $bet_data   = $contract->{bet_data};
    my $underlying = $bet_data->{underlying_symbol};

    # print "CONTRACT GROUP: $contract_group\nUNDERLYING GROUP: $underlying_group\n";

    my $is_atm = ($bet_data->{short_code} =~ /_SOP_/) ? 't' : 'f';

    my $expiry_type;
    if ($bet_data->{tick_count} and $bet_data->{tick_count} > 0) {
        $expiry_type = 'tick';
    } elsif ($bet_data->{expiry_daily}) {
        $expiry_type = 'daily';
    } elsif ((Date::Utility->new($bet_data->{expiry_time})->epoch - Date::Utility->new($bet_data->{start_time})->epoch) <= 300) {    # 5 minutes
        $expiry_type = 'ultra_short';
    } else {
        $expiry_type = 'intraday';
    }

    my @attributes = ($underlying, $contract_group, $expiry_type, $is_atm);
    my @combinations = BOM::CompanyLimits::Helpers::get_all_key_combinations(@attributes);

    # Merge another array that substitutes underlying with underlying group
    my @underlyinggroup_combinations = grep(/^${underlying}\,/, @combinations);
    foreach my $x (@underlyinggroup_combinations) {
        substr($x, 0, length($underlying)) = $underlying_group;
    }

    return (@combinations, @underlyinggroup_combinations);
}

1;

