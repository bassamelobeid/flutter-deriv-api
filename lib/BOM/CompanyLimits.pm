package BOM::CompanyLimits;
use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use Future::AsyncAwait;
use Future::Utils;
use Date::Utility;
use Data::Dumper;
use BOM::CompanyLimits::Helpers qw(get_redis);
use BOM::CompanyLimits::Combinations;
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

    return;
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

    return;
}

sub add_buy_contract {
    my ($contract) = @_;
    my ($bet_data, $account_data) = @$contract{qw/bet_data account_data/};

    my $underlying      = $bet_data->{underlying_symbol};
    my $landing_company = $account_data->{landing_company};

    # TODO: incrby and check turnover
    my $attributes = BOM::CompanyLimits::Combinations::get_attributes_from_contract($contract);
    use Data::Dumper;
    my ($company_limits) = BOM::CompanyLimits::Combinations::get_limit_settings_combinations($attributes);

    my $limits_future  = BOM::CompanyLimits::Limits::query_limits($landing_company, $company_limits);
    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($contract);
    my @breaches       = Future->needs_all(
        check_realized_loss(get_redis($landing_company, 'realized_loss'), $landing_company, $limits_future, $company_limits),
        check_potential_loss(get_redis($landing_company, 'potential_loss'), $landing_company, $limits_future, $company_limits, $potential_loss),
    )->get();
    my $limits = $limits_future->get();

    if (@breaches) {
        # TODO: send event to publish email to quants
        # print 'BREACH', Dumper(\@breaches);

        foreach my $breach (@breaches) {
            if ($breach->[0] == POTENTIAL_LOSS_TOTALS or $breach->[0] == REALIZED_LOSS_TOTALS) {
                die ['BI051'];    # To retain much of existing functionality, make it look as if the error comes from db
            }
        }

        die 'Unknown Limit Breach';
    }
}

sub reverse_buy_contract {
    my ($contract) = @_;

    my $landing_company = $contract->{account_data}->{landing_company};
    # TODO: incrby and check turnover
    my $attributes       = BOM::CompanyLimits::Combinations::get_attributes_from_contract($contract);
    my ($company_limits) = BOM::CompanyLimits::Combinations::get_limit_settings_combinations($attributes);
    my $potential_loss   = BOM::CompanyLimits::LossTypes::calc_potential_loss($contract);

    Future->needs_all(
        incr_loss_hash(get_redis($landing_company, 'potential_loss'), $company_limits, "$landing_company:potential_loss", -$potential_loss),
    )->get();

    return;
}

async sub check_realized_loss {
    my ($redis, $landing_company, $limits_future, $combinations) = @_;

    my $response = $redis->hmget("$landing_company:realized_loss", @$combinations);

    return _check_breaches($response, $limits_future, $combinations, REALIZED_LOSS_TOTALS);
}

async sub check_potential_loss {
    my ($redis, $landing_company, $limits_future, $combinations, $potential_loss) = @_;

    my $response = await incr_loss_hash($redis, $combinations, "$landing_company:potential_loss", $potential_loss);

    return _check_breaches($response, $limits_future, $combinations, POTENTIAL_LOSS_TOTALS);
}

sub _check_breaches {
    my ($response, $limits_future, $combinations, $loss_type_idx) = @_;

    my @breaches;
    my $limits = $limits_future->get();
    foreach my $i (0 .. $#$combinations) {
        my $comb  = $combinations->[$i];
        my $limit = $limits->{$comb};
        if (    $limit
            and $limit->[$loss_type_idx]
            and $response->[$i] > $limit->[$loss_type_idx])
        {
            push(@breaches, [$loss_type_idx, $comb, $limit->[$loss_type_idx], $response->[$i]]);
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

    my $attributes = BOM::CompanyLimits::Combinations::get_attributes_from_contract($contract);
    my ($company_limits) = BOM::CompanyLimits::Combinations::get_limit_settings_combinations($attributes);

    # For sell, we increment totals but do not check if they exceed limits;
    # we only block buys, not sells.
    my $realized_loss  = BOM::CompanyLimits::LossTypes::calc_realized_loss($contract);
    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($contract);

    # On sells, we increment realized loss and deduct potential loss
    # Since no checks are done, we simply increment and discard the response
    Future->needs_all(
        incr_loss_hash(get_redis($landing_company, 'realized_loss'),  $company_limits, "$landing_company:realized_loss",  $realized_loss),
        incr_loss_hash(get_redis($landing_company, 'potential_loss'), $company_limits, "$landing_company:potential_loss", -$potential_loss),
    );
}

async sub incr_loss_hash {
    my ($redis, $combinations, $hash_name, $incrby) = @_;

    $redis->multi(sub { });
    foreach my $p (@$combinations) {
        $redis->hincrbyfloat($hash_name, $p, $incrby, sub { });
    }

    my $response;
    $redis->exec(sub { $response = $_[1]; });
    $redis->mainloop;

    return $response;

}

1;

