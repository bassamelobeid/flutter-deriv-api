package BOM::CompanyLimits;
use strict;
use warnings;

use BOM::CompanyLimits::Helpers qw(get_redis);
use BOM::CompanyLimits::Combinations;
use BOM::CompanyLimits::LossTypes;
use BOM::CompanyLimits::Stats;
use LandingCompany::Registry;

# Everything in this file is in buy path

# add_buy_contract returns the same list of check results: undef
# if passed, an error otherwise. Same method is used for both buys and
# batch buys.
#
# For global limits, the increments are accumulated across each client,
# and its breaches will revert all buys within the batch buys before
# it could enter the database. The rationale here is that if it is going
# to breach global limits (presumably large), a difference of a few contracts
# is not going to make much difference.
#
# For breaches in user specific limits however, we filter these clients
# out before entering the database.
sub add_buy_contract {
    my ($params) = @_;
    my ($bet_data, $currency, $clients) = @$params{qw/bet_data currency clients/};

    # For batch operations, all clients will have the same broker code, and thus have
    # the same landing company
    my $landing_company = $clients->[0]->landing_company->short;
    return unless LandingCompany::Registry::get($landing_company);

    my $attributes          = BOM::CompanyLimits::Combinations::get_attributes_from_contract($bet_data);
    my $global_combinations = BOM::CompanyLimits::Combinations::get_global_limit_combinations($attributes);
    my $user_combinations;
    my $turnover_combinations;

    foreach my $client (@$clients) {
        my $combinations = BOM::CompanyLimits::Combinations::get_user_limit_combinations($client->binary_user_id, $attributes);
        my $t_combinations = BOM::CompanyLimits::Combinations::get_turnover_incrby_combinations($client->binary_user_id, $attributes);
        push(@$user_combinations,     @$combinations);
        push(@$turnover_combinations, @$t_combinations);
    }

    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($bet_data, $currency);
    _incr_loss_hash($landing_company, 'potential_loss', $global_combinations, scalar @$clients * $potential_loss, $user_combinations,
        $potential_loss);
    my $turnover = BOM::CompanyLimits::LossTypes::calc_turnover($bet_data, $currency);
    _incr_loss_hash($landing_company, 'turnover', $turnover_combinations, $turnover);
}
# TODO: reintroduce stats object
sub reverse_buy_contract {
    my ($params) = @_;
    my ($bet_data, $currency, $clients, $errors) = @$params{qw/bet_data currency clients errors/};

    # TODO: reverse buys for batch buys...?
    return unless _should_reverse_buy_contract($errors->[0]);

    # For batch operations, all clients will have the same broker code, and thus have
    # the same landing company
    my $landing_company = $clients->[0]->landing_company->short;
    return unless LandingCompany::Registry::get($landing_company);

    my $attributes          = BOM::CompanyLimits::Combinations::get_attributes_from_contract($bet_data);
    my $global_combinations = BOM::CompanyLimits::Combinations::get_global_limit_combinations($attributes);
    my $user_combinations;
    my $turnover_combinations;

    foreach my $client (@$clients) {
        my $combinations = BOM::CompanyLimits::Combinations::get_user_limit_combinations($client->binary_user_id, $attributes);
        my $t_combinations = BOM::CompanyLimits::Combinations::get_turnover_incrby_combinations($client->binary_user_id, $attributes);
        push(@$user_combinations,     @$combinations);
        push(@$turnover_combinations, @$t_combinations);
    }

    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($bet_data, $currency);
    _incr_loss_hash($landing_company, 'potential_loss', $global_combinations, scalar @$clients * -$potential_loss,
        $user_combinations, -$potential_loss);
    my $turnover = BOM::CompanyLimits::LossTypes::calc_turnover($bet_data, $currency);
    _incr_loss_hash($landing_company, 'turnover', $turnover_combinations, -$turnover);
}

sub add_sell_contract {
    my ($params) = @_;
    my ($bet_data, $currency, $clients) = @$params{qw/bet_data currency clients/};

    my $landing_company = $clients->[0]->landing_company->short;
    return unless LandingCompany::Registry::get($landing_company);

    my $attributes          = BOM::CompanyLimits::Combinations::get_attributes_from_contract($bet_data);
    my $global_combinations = BOM::CompanyLimits::Combinations::get_global_limit_combinations($attributes);
    my $user_combinations;
    my $turnover_combinations;

    foreach my $client (@$clients) {
        my $combinations = BOM::CompanyLimits::Combinations::get_user_limit_combinations($client->binary_user_id, $attributes);
        my $t_combinations = BOM::CompanyLimits::Combinations::get_turnover_incrby_combinations($client->binary_user_id, $attributes);
        push(@$user_combinations,     @$combinations);
        push(@$turnover_combinations, @$t_combinations);
    }

    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($bet_data, $currency);
    _incr_loss_hash($landing_company, 'potential_loss', $global_combinations, scalar @$clients * -$potential_loss,
        $user_combinations, -$potential_loss);
    my $realized_loss = BOM::CompanyLimits::LossTypes::calc_realized_loss($bet_data, $currency);
    _incr_loss_hash($landing_company, 'realized_loss', $global_combinations, $realized_loss, $user_combinations, $realized_loss);

    return;
}

# 3rd param is a list combination-incrby pair
sub _incr_loss_hash {
    my ($landing_company, $loss_type, @incr_pair) = @_;

    my $redis = get_redis($landing_company, $loss_type);
    my $hash_name = "$landing_company:$loss_type";
    my $response;
    $redis->multi(sub { });
    for (my $i = 0; $i < @incr_pair; $i += 2) {
        my ($combinations, $incrby) = @incr_pair[$i, $i + 1];
        foreach my $p (@$combinations) {
            $redis->hincrbyfloat($hash_name, $p, $incrby, sub { });
        }
    }
    $redis->exec(sub { $response = $_[1]; });
    $redis->mainloop;

    return $response;
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

1;

