package BOM::CompanyLimits;
use strict;
use warnings;

use BOM::CompanyLimits::Helpers qw(get_redis);
use BOM::CompanyLimits::Combinations;
use BOM::CompanyLimits::LossTypes;
use BOM::CompanyLimits::Stats;
use LandingCompany::Registry;

# Everything in this file is in buy path

sub add_buy_contract {
    my ($contract) = @_;
    my ($bet_data, $account_data) = @$contract{qw/bet_data account_data/};

    my $landing_company = $account_data->{landing_company};
    return unless LandingCompany::Registry::get($landing_company);

    my $stats_dat = BOM::CompanyLimits::Stats::stats_start($contract, 'buy');

    my $attributes            = BOM::CompanyLimits::Combinations::get_attributes_from_contract($contract);
    my $limits_combinations   = BOM::CompanyLimits::Combinations::get_limit_settings_combinations($attributes);
    my $turnover_combinations = BOM::CompanyLimits::Combinations::get_turnover_incrby_combinations($attributes);

    incr_potential_loss($contract, $landing_company, $limits_combinations);
    incr_turnover($contract, $landing_company, $turnover_combinations);

    BOM::CompanyLimits::Stats::stats_stop($stats_dat);
    return;
}

sub reverse_buy_contract {
    my ($contract, $error) = @_;

    my $landing_company = $contract->{account_data}->{landing_company};
    return unless LandingCompany::Registry::get($landing_company);

    # Should be very careful here; we do not want to revert a buy we have not incremented in Redis!
    return unless (_should_reverse_buy_contract($error));

    my $stats_dat             = BOM::CompanyLimits::Stats::stats_start($contract, 'reverse_buy');
    my $attributes            = BOM::CompanyLimits::Combinations::get_attributes_from_contract($contract);
    my $limits_combinations   = BOM::CompanyLimits::Combinations::get_limit_settings_combinations($attributes);
    my $turnover_combinations = BOM::CompanyLimits::Combinations::get_turnover_incrby_combinations($attributes);

    incr_potential_loss($contract, $landing_company, $limits_combinations, {reverse => 1});
    incr_turnover($contract, $landing_company, $turnover_combinations, {reverse => 1});

    BOM::CompanyLimits::Stats::stats_stop($stats_dat);
    return;
}

sub _should_reverse_buy_contract {
    my ($error) = @_;

    if (ref $error eq 'ARRAY') {
        my $error_code = $error->[0];
        return 0 if $error_code eq 'BI054'    # no underlying group mapping
            or $error_code eq 'BI053';        # no contract group mapping

        return 1;
    }

    return 0;
}

sub add_sell_contract {
    my ($contract) = @_;

    my $landing_company = $contract->{account_data}->{landing_company};
    return unless LandingCompany::Registry::get($landing_company);

    my $stats_dat           = BOM::CompanyLimits::Stats::stats_start($contract, 'sell');
    my $attributes          = BOM::CompanyLimits::Combinations::get_attributes_from_contract($contract);
    my $limits_combinations = BOM::CompanyLimits::Combinations::get_limit_settings_combinations($attributes);

    # For sell, we increment totals but do not check if they exceed limits;
    # we only block buys, not sells.

    # On sells, we increment realized loss and deduct potential loss
    # Since no checks are done, we simply increment and discard the response
    incr_realized_loss($contract, $landing_company, $limits_combinations);
    incr_potential_loss($contract, $landing_company, $limits_combinations, {reverse => 1});

    BOM::CompanyLimits::Stats::stats_stop($stats_dat);
    return;
}

sub incr_realized_loss {
    my ($contract, $landing_company, $limits_combinations) = @_;
    my $realized_loss = BOM::CompanyLimits::LossTypes::calc_realized_loss($contract);

    return _incr_loss_hash($landing_company, 'realized_loss', $limits_combinations, $realized_loss);
}

sub incr_potential_loss {
    my ($contract, $landing_company, $limits_combinations, $options) = @_;
    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($contract);
    $potential_loss = -$potential_loss if $options->{reverse};

    return _incr_loss_hash($landing_company, 'potential_loss', $limits_combinations, $potential_loss);
}

sub incr_turnover {
    my ($contract, $landing_company, $turnover_combinations, $options) = @_;
    my $turnover = BOM::CompanyLimits::LossTypes::calc_turnover($contract);
    $turnover = -$turnover if $options->{reverse};

    return _incr_loss_hash($landing_company, 'turnover', $turnover_combinations, -$turnover);
}

sub _incr_loss_hash {
    my ($landing_company, $loss_type, $combinations, $incrby) = @_;

    my $redis = get_redis($landing_company, $loss_type);
    my $hash_name = "$landing_company:$loss_type";
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

