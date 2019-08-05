package BOM::CompanyLimits;
use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use Future::AsyncAwait;
use Future::Utils;
use Date::Utility;
use Data::Dumper;
use BOM::CompanyLimits::Helpers qw(get_all_key_combinations get_redis);
use BOM::CompanyLimits::Limits;
use BOM::CompanyLimits::LossTypes;

=head1 NAME


=cut

use constant {
    POTENTIAL_LOSS_TOTALS => 0,
    REALIZED_LOSS_TOTALS  => 1,
};

sub set_underlying_groups {
    # POC, we should see which broker code to use
    my $dbic = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic;

    my $sql = q{
	SELECT symbol, market FROM bet.market;
    };
    my $bet_market = $dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef) });

    my @symbol_underlying;
    push @symbol_underlying, @$_ foreach (@$bet_market);

    # TODO: we are hard coding the landing company when setting limits
    get_redis('svg', 'limit_setting')->hmset('UNDERLYINGGROUPS', @symbol_underlying);
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
    get_redis('svg', 'limit_setting')->hmset('CONTRACTGROUPS', @contract_grp);
}

sub add_buy_contract {
    my ($contract) = @_;
    my ($bet_data, $account_data) = @$contract{qw/bet_data account_data/};

    my $underlying = $bet_data->{underlying_symbol};
    my $landing_company = $account_data->{landing_company};
    my ($contract_group, $underlying_group) = _get_attr_groups($landing_company, $bet_data);

    # print 'BET DATA: ', Dumper($contract);
    my @combinations = _get_combinations($contract, $underlying_group, $contract_group);

    my $limits_future = BOM::CompanyLimits::Limits::query_limits($underlying, \@combinations);
    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($contract);
    my @breaches = Future->needs_all(
        check_realized_loss(get_redis($landing_company, 'realized_loss'), $landing_company, $limits_future, \@combinations),
        check_potential_loss(get_redis($landing_company, 'potential_loss'), $landing_company, $limits_future, \@combinations, $potential_loss),
    )->get();
    my $limits = $limits_future->get();

    if (@breaches) {
        # print 'BREACH', Dumper(\@breaches);
        die 'BREACH', Dumper(\@breaches);
    }
}

async sub check_realized_loss {
    my ($redis, $landing_company, $limits_future, $combinations) = @_;

    my $response = $redis->hmget("$landing_company:realized_loss", @$combinations);

    return _check_breaches($response, $limits_future, $combinations, 'realized_loss', REALIZED_LOSS_TOTALS);
}

async sub check_potential_loss {
    my ($redis, $landing_company, $limits_future, $combinations, $potential_loss) = @_;

    my $response = await incr_loss_hash($redis, $combinations, "$landing_company:potential_loss", $potential_loss);

    return _check_breaches($response, $limits_future, $combinations, 'potential_loss', POTENTIAL_LOSS_TOTALS);
}

sub _check_breaches {
    my ($response, $limits_future, $combinations, $loss_type, $loss_type_idx) = @_;

    my @breaches;

    my $limits = $limits_future->get();
    foreach my $i (0 .. $#$combinations) {
        my $comb  = $combinations->[$i];
        my $limit = $limits->{$comb};
        if (    $limit
            and $limit->[$loss_type_idx]
            and $response->[$i] > $limit->[$loss_type_idx])
        {
            push(@breaches, [$loss_type, $comb, $limit->[$loss_type_idx], $response->[$i]]);
        }
    }

    return @breaches;
}

sub add_sell_contract {
    my ($contract)   = @_;
    my $bet_data     = $contract->{bet_data};
    my $account_data = $contract->{account_data};
    # print 'BET DATA: ', Dumper($contract);

    my $landing_company = $account_data->{landing_company};
    my ($contract_group, $underlying_group) = _get_attr_groups($landing_company, $bet_data);

    my @combinations = _get_combinations($contract, $underlying_group, $contract_group);

    # For sell, we increment totals but do not check if they exceed limits;
    # we only block buys, not sells.
    my $realized_loss = BOM::CompanyLimits::LossTypes::calc_realized_loss($contract);
    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($contract);

    # On sells, we increment realized loss and deduct potential loss
    # Since no checks are done, we simply increment and discard the response
    Future->needs_all(
        incr_loss_hash(get_redis($landing_company, 'realized_loss'), \@combinations, "$landing_company:realized_loss", $realized_loss),
        incr_loss_hash(get_redis($landing_company, 'potential_loss'), \@combinations, "$landing_company:potential_loss", -$potential_loss),
    );
}

async sub incr_loss_hash {
    my ($redis, $combinations, $hash_name, $incrby) = @_;

    $redis->multi(sub { });
    foreach my $p (@$combinations) {
        $redis->hincrbyfloat($hash_name, $p, $incrby, sub { });
    }

    my $response;
    $redis->exec(sub { $response  = $_[1]; });
    $redis->mainloop;

    return $response;

}

sub _get_attr_groups {
    my ($landing_company, $bet_data) = @_;

    my ($contract_group, $underlying_group);
    my $redis = get_redis($landing_company, 'limit_setting');
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

sub _get_combinations {
    my ($contract, $underlying_group, $contract_group) = @_;
    my $bet_data   = $contract->{bet_data};
    my $underlying = $bet_data->{underlying_symbol};

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
    my @combinations = get_all_key_combinations(@attributes);

    # Merge another array that substitutes underlying with underlying group
    # Since we know that the 1st attribute is the underlying, each index in which
    # the 1st bit is 1 has underlying:
    my @underlyinggroup_combinations;
    my $underlying_len = length($underlying);
    foreach my $i (1 .. scalar @combinations) {
        if (($i & 1) == 1) {
            my $k = $underlying_group . substr($combinations[$i - 1], $underlying_len);
            push(@underlyinggroup_combinations, $k);
        }
    }

    return (@combinations, @underlyinggroup_combinations);
}

1;

