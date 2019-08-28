package BOM::CompanyLimits;
use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
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
    TURNOVER_TOTALS       => 2,
};

sub add_buy_contract {
    my ($contract) = @_;
    my ($bet_data, $account_data) = @$contract{qw/bet_data account_data/};

    my $landing_company = $account_data->{landing_company};

    my $attributes            = BOM::CompanyLimits::Combinations::get_attributes_from_contract($contract);
    my ($company_limits)      = BOM::CompanyLimits::Combinations::get_limit_settings_combinations($attributes);
    my $turnover_combinations = BOM::CompanyLimits::Combinations::get_turnover_incrby_combinations($attributes);

    my $limits_future  = BOM::CompanyLimits::Limits::query_limits($landing_company, $company_limits);
    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($contract);
    my $turnover       = BOM::CompanyLimits::LossTypes::calc_turnover($contract);
    my @breaches       = Future->needs_all(
        check_realized_loss($landing_company, $limits_future, $company_limits),
        check_potential_loss($landing_company, $limits_future, $company_limits, $potential_loss),
        check_turnover($landing_company, $limits_future, $turnover_combinations, $turnover),
    )->get();

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
    my ($contract, $error) = @_;

    # Should be very careful here; we do not want to revert a buy we have not incremented in Redis!
    return unless (_should_reverse_buy_contract($error));

    my $landing_company       = $contract->{account_data}->{landing_company};
    my $attributes            = BOM::CompanyLimits::Combinations::get_attributes_from_contract($contract);
    my $company_limits        = BOM::CompanyLimits::Combinations::get_limit_settings_combinations($attributes);
    my $potential_loss        = BOM::CompanyLimits::LossTypes::calc_potential_loss($contract);
    my $turnover              = BOM::CompanyLimits::LossTypes::calc_turnover($contract);
    my $turnover_combinations = BOM::CompanyLimits::Combinations::get_turnover_incrby_combinations($attributes);

    Future->needs_all(
        incr_loss_hash($landing_company, 'potential_loss', $company_limits,        -$potential_loss),
        incr_loss_hash($landing_company, 'turnover',       $turnover_combinations, -$turnover),
    )->get();

    return;
}

sub _should_reverse_buy_contract {
    my ($error) = @_;

    if (ref $error eq 'ARRAY') {
        my $error_code = $error->[0];
        return 0 if ($error_code eq 'BI054'); # no underlying group mapping

        return 1;
    }

    return 0;
}

async sub check_realized_loss {
    my ($landing_company, $limits_future, $combinations) = @_;

    my $redis = get_redis($landing_company, 'realized_loss');
    my $response = $redis->hmget("$landing_company:realized_loss", @$combinations);

    return _check_breaches($response, $limits_future, $combinations, REALIZED_LOSS_TOTALS);
}

async sub check_potential_loss {
    my ($landing_company, $limits_future, $combinations, $potential_loss) = @_;

    my $response = await incr_loss_hash($landing_company, 'potential_loss', $combinations, $potential_loss);

    my $app_config = BOM::Config::Runtime->instance->app_config;

    return _check_breaches($response, $limits_future, $combinations, POTENTIAL_LOSS_TOTALS);
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
async sub check_turnover {
    my ($landing_company, $limits_future, $combinations, $turnover) = @_;

    my $turnover_response = await incr_loss_hash($landing_company, 'turnover', $combinations, $turnover);

    my @response;
    @response[6, 7, 18, 19, 24 .. 27] = @{$turnover_response}[0 .. 3, 1, 1, 3, 3];

    return _check_breaches(\@response, $limits_future, $combinations, TURNOVER_TOTALS);
}

sub _check_breaches {
    my ($response, $limits_future, $combinations, $loss_type_idx) = @_;
    # TODO: should skip global potential/realized loss check if some app_config setting is disabled

    my @breaches;
    my $limits = $limits_future->get();
    foreach my $i (0 .. $#$combinations) {
        my $comb  = $combinations->[$i];
        my $limit = $limits->{$comb};
        if (    $limit
            and $limit->[$loss_type_idx] ne ''
            and $response->[$i] > $limit->[$loss_type_idx])
        {
            push(@breaches, [$loss_type_idx, $comb, $limit->[$loss_type_idx], $response->[$i]]);
        }
    }

    return @breaches;
}

sub add_sell_contract {
    my ($contract) = @_;

    my $landing_company  = $contract->{account_data}->{landing_company};
    my $attributes       = BOM::CompanyLimits::Combinations::get_attributes_from_contract($contract);
    my ($company_limits) = BOM::CompanyLimits::Combinations::get_limit_settings_combinations($attributes);

    # For sell, we increment totals but do not check if they exceed limits;
    # we only block buys, not sells.
    my $realized_loss  = BOM::CompanyLimits::LossTypes::calc_realized_loss($contract);
    my $potential_loss = BOM::CompanyLimits::LossTypes::calc_potential_loss($contract);

    # On sells, we increment realized loss and deduct potential loss
    # Since no checks are done, we simply increment and discard the response
    Future->needs_all(
        incr_loss_hash($landing_company, 'realized_loss',  $company_limits, $realized_loss),
        incr_loss_hash($landing_company, 'potential_loss', $company_limits, -$potential_loss),
    );
}

async sub incr_loss_hash {
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

