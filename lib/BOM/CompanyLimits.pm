package BOM::CompanyLimits;
use strict;
use warnings;

use ExchangeRates::CurrencyConverter;
use BOM::CompanyLimits::Helpers qw(get_redis);
use BOM::CompanyLimits::Combinations;
use BOM::CompanyLimits::Stats;
use LandingCompany::Registry;

# TODO: breach implementation to come in 2nd phase...

=head1 NAME

BOM::CompanyLimits

=head1 SYNOPSIS

    my $company_limits = BOM::CompanyLimits->new(
        contract_data => $contract_data,
        currency => $currency,
        landing_company => $landing_company,
    );

    # @clients is list of client objects
    my $result = $company_limits->add_buys(@clients)
    my $result = $company_limits->add_sells(@clients)


    $company_limits->reverse_buys(@clients)

=cut

sub new {
    my ($class, %params) = @_;
    my $self = bless {}, $class;

    my $landing_company = $params{landing_company};

    die "Unsupported landing company $landing_company" unless LandingCompany::Registry::get($landing_company);

    $self->{landing_company} = $landing_company;
    $self->{currency}        = $params{currency};
    $self->{contract_data}   = $params{contract_data};

    my $stat_dat = BOM::CompanyLimits::Stats::stats_start($self, 'init');

    my $attributes = BOM::CompanyLimits::Combinations::get_attributes_from_contract($params{contract_data});
    $self->{global_combinations} = BOM::CompanyLimits::Combinations::get_global_limit_combinations($attributes);
    $self->{attributes}          = $attributes;

    BOM::CompanyLimits::Stats::stats_stop($stat_dat);

    return $self;
}

sub add_buys {
    my ($self, @clients) = @_;

    my $stat_dat = BOM::CompanyLimits::Stats::stats_start($self, 'buys');
    $self->_incr_for_buys(1, @clients);

    $self->{has_add_buys} = 1;
    BOM::CompanyLimits::Stats::stats_stop($stat_dat);
    return;
}

sub reverse_buys {
    my ($self, @clients) = @_;

    # We only reverse buys for which errors come from database. If buys are blocked
    # because of company limits, it should not end up here.
    die "Cannot reverse buys unless add_buys is first called" unless $self->{has_add_buys};

    my $stat_dat = BOM::CompanyLimits::Stats::stats_start($self, 'reverse_buys');

    $self->_incr_for_buys(-1, @clients);
    BOM::CompanyLimits::Stats::stats_stop($stat_dat);

    return;
}

sub add_sells {
    my ($self, @clients) = @_;

    my $stat_dat = BOM::CompanyLimits::Stats::stats_start($self, 'sells');

    my $attributes = $self->{attributes};
    my $user_combinations;

    foreach my $client (@clients) {
        my $combinations = BOM::CompanyLimits::Combinations::get_user_limit_combinations($client->binary_user_id, $attributes);
        push(@$user_combinations, @$combinations);
    }

    # On sells, potential loss is deducted from open bets. Since exchange rates can vary in different points of time,
    # the potential loss we deduct here may not be the same value that we add during buys. This is something we would
    # need to live with. To mitigate this, we sync the potential loss hash table in Redis with the database in a daily
    # basis.
    # NOTE: potential loss sync to be added later.
    my $contract_data = $self->{contract_data};
    my $potential_loss = ExchangeRates::CurrencyConverter::in_usd($contract_data->{payout_price} - $contract_data->{buy_price}, $self->{currency});
    $self->_incrby_loss_hash('potential_loss', $self->{global_combinations}, scalar @clients * -$potential_loss,
        $user_combinations, -$potential_loss);

    my $realized_loss = ExchangeRates::CurrencyConverter::in_usd($contract_data->{sell_price} - $contract_data->{buy_price}, $self->{currency});
    $self->_incrby_loss_hash('realized_loss', $self->{global_combinations}, scalar @clients * $realized_loss, $user_combinations, $realized_loss);

    BOM::CompanyLimits::Stats::stats_stop($stat_dat);
    return;
}

sub _incrby_loss_hash {
    my ($self, $loss_type, @incr_pair) = @_;

    # A note about the precision of values in Redis: The most accurate calculation of the loss for
    # currencies not in USD is always the current exchange rate. However, the exchange rate we use to
    # increment the loss is always the exchange rate at the time we calculate the increment. A solution
    # to this would probably to place the currency as a dimension, but performance would take a hit.
    # So as of now our current solution is to live with this discrepacy. Since realized loss and turnover
    # resets daily and potential loss is synced daily, the errors are accumulated for at most a day.
    #
    # Most currencies are rather stable, save for cryptos (i.e. bitcoin) that can fluctuate rather
    # unpredictably. However, we would expect that its growth would be gradual across a few weeks, but
    # its crash can happen within a day. What this means is that we always overestimate the loss, which
    # is fine since these are our own limits.
    my $landing_company = $self->{landing_company};
    my $redis           = get_redis($landing_company, $loss_type);
    my $hash_name       = "$landing_company:$loss_type";
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

# Reused for both buys and reverse buys
sub _incr_for_buys {
    my ($self, $multiplier, @clients) = @_;

    my $user_combinations;
    my $turnover_combinations;
    my $attributes = $self->{attributes};

    foreach my $client (@clients) {
        my $combinations = BOM::CompanyLimits::Combinations::get_user_limit_combinations($client->binary_user_id, $attributes);
        my $t_combinations = BOM::CompanyLimits::Combinations::get_turnover_incrby_combinations($client->binary_user_id, $attributes);
        push(@$user_combinations,     @$combinations);
        push(@$turnover_combinations, @$t_combinations);
    }

    my @responses;
    my $contract_data = $self->{contract_data};

    # Exchange rates may change if queried at different times. This could cause the loss values
    # we increment during buys to be different when we reverse them - in the time we wait for the
    # database to reply, the exchange rate may have changed. To workaround this,  we cache the
    # potential loss and turnover so that the same increments are used in both buys and reverse buys.
    my $potential_loss =
        ($self->{potential_loss} //=
            ExchangeRates::CurrencyConverter::in_usd($contract_data->{payout_price} - $contract_data->{buy_price}, $self->{currency})) * $multiplier;

    push @responses,
        $self->_incrby_loss_hash(
        'potential_loss',
        $self->{global_combinations},
        scalar @clients * $potential_loss,
        $user_combinations, $potential_loss
        );

    my $turnover = ($self->{turnover} //= ExchangeRates::CurrencyConverter::in_usd($contract_data->{buy_price}, $self->{currency})) * $multiplier;

    push @responses, $self->_incrby_loss_hash('turnover', $turnover_combinations, $turnover);

    return @responses;
}

1;

