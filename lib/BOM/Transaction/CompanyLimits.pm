package BOM::Transaction::CompanyLimits;

use 5.024;
use strict;
use warnings;

use ExchangeRates::CurrencyConverter;
use BOM::Config::RedisReplicated;
use BOM::Config::RedisTransactionLimits;
use BOM::Transaction::Limits::Combinations;
use DataDog::DogStatsd::Helper qw(stats_timed);

=head1 NAME

BOM::Transaction::CompanyLimits

=head1 SYNOPSIS

    my $company_limits = BOM::Transaction::CompanyLimits->new(
        contract_data => $contract_data,
        currency => $currency,
        landing_company => $landing_company,
    );

    # @clients is list of client objects
    my $result = $company_limits->add_buys(@clients)
    my $result = $company_limits->add_sells(@clients)


    $company_limits->reverse_buys(@clients)

=cut

# Once we decide to activate these limits, this BEGIN block and the
# "... if fake_it;" statement in the constructor
# below have to be removed. No other changes are needed.
BEGIN {
    *BOM::Transaction::CompanyLimits::Fake::add_buys = *BOM::Transaction::CompanyLimits::Fake::add_sells =
        *BOM::Transaction::CompanyLimits::Fake::reverse_buys = sub { };
    *fake_it = sub {
        return 'yes' ne (readlink "/etc/rmg/turn-on-company-limits" // "");
        }
        unless defined &fake_it;
}

sub new {
    my ($class, %params) = @_;
    return bless {}, __PACKAGE__ . '::Fake' if fake_it;

    my $self = bless {}, $class;
    my $landing_company = $params{landing_company};
    $self->{landing_company} = $landing_company->short;
    $self->{is_virtual}      = $landing_company->is_virtual;
    $self->{currency}        = $params{currency};
    $self->{contract_data}   = $params{contract_data};
    $self->{redis}           = BOM::Config::RedisTransactionLimits::redis_limits_write($landing_company);

    my $attributes = BOM::Transaction::Limits::Combinations::get_attributes_from_contract($params{contract_data});
    $self->{global_combinations} = BOM::Transaction::Limits::Combinations::get_global_limit_combinations($attributes);
    $self->{attributes}          = $attributes;

    return $self;
}

sub dd_opts {
    my $self = shift;

    state $opts = {tags => ["rmgenv:" . BOM::Config::env]};
    $opts->{tags}->[1] = 'landing_company:' . $self->{landing_company};
    $opts->{tags}->[2] = 'virtual:' . ($self->{is_virtual} ? 'yes' : 'no');

    return $opts;
}

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
sub add_buys {
    my ($self, @clients) = @_;

    return stats_timed {
        $self->_add_buys(@clients);
    }
    'companylimits.buy' => $self->dd_opts;
}

sub _add_buys {
    my ($self, @clients) = @_;

    my $user_combinations = $self->_get_combinations_with_clients(\&BOM::Transaction::Limits::Combinations::get_user_limit_combinations, \@clients);
    my $turnover_combinations = $self->_get_combinations_with_clients(\&BOM::Transaction::Limits::Combinations::get_turnover_combinations, \@clients);

    my $contract_data = $self->{contract_data};

    my ($response, $hash_name);
    my $redis = $self->{redis};

    $redis->multi(sub { });

    # TODO: Though we do not use realized loss for limits now, we query anyway to gauge performance for the first phase
    $hash_name = $self->{landing_company} . ':realized_loss';
    $redis->hmget($hash_name, my @real_loss_keys = (@{$self->{global_combinations}}, @{$user_combinations}), sub { });

    # Exchange rates may change if queried at different times. This could cause the loss values
    # we increment during buys to be different when we reverse them - in the time we wait for the
    # database to reply, the exchange rate may have changed. To workaround this,  we cache the
    # potential loss and turnover so that the same increments are used in both buys and reverse buys.
    my @pot_loss_keys;
    unless ($self->_has_no_payout) {
        my $potential_loss = $self->{potential_loss} =
            ExchangeRates::CurrencyConverter::in_usd($contract_data->{payout_price} - $contract_data->{buy_price}, $self->{currency});
        $hash_name = $self->{landing_company} . ':potential_loss';
        $redis->hincrbyfloat($hash_name, $_, $potential_loss * @clients, sub { }) foreach @{$self->{global_combinations}};
        $redis->hincrbyfloat($hash_name, $_, $potential_loss,            sub { }) foreach @{$user_combinations};

        push @pot_loss_keys, @{$self->{global_combinations}}, @{$user_combinations};
    }

    my $turnover = $self->{turnover} = ExchangeRates::CurrencyConverter::in_usd($contract_data->{buy_price}, $self->{currency});
    $hash_name = $self->{landing_company} . ':turnover';
    $redis->hincrbyfloat($hash_name, $_, $turnover, sub { }) foreach @{$turnover_combinations};

    $redis->exec(
        sub {
            $response = $_[1];
            # Flatten out the array response from realized_loss hmget
            splice @$response, 0, 1, @{$response->[0]};
        });
    $redis->mainloop;

    $self->{has_add_buys} = 1;

    # TODO: breach check implementation to come in 2nd phase...
    return $response,
        realized_loss_keys  => \@real_loss_keys,
        potential_loss_keys => \@pot_loss_keys,
        turnover_keys       => $turnover_combinations;
}

sub reverse_buys {
    my ($self, @clients) = @_;

    # We only reverse buys for which errors come from database. If buys are blocked
    # because of company limits, it should not end up here.
    die "Cannot reverse buys unless add_buys is first called" unless $self->{has_add_buys};

    return stats_timed {
        $self->_reverse_buys(@clients);
    }
    'companylimits.reverse_buy' => $self->dd_opts;
}

sub _reverse_buys {
    my ($self, @clients) = @_;

    # These combinations cannot be cached; we cannot assume that in reversing buys
    # the exact same client list will be passed in
    my $user_combinations = $self->_get_combinations_with_clients(\&BOM::Transaction::Limits::Combinations::get_user_limit_combinations, \@clients);
    my $turnover_combinations = $self->_get_combinations_with_clients(\&BOM::Transaction::Limits::Combinations::get_turnover_combinations, \@clients);

    my $hash_name;
    my $redis = $self->{redis};
    $redis->multi(sub { });

    unless ($self->_has_no_payout) {
        my $potential_loss = -$self->{potential_loss};
        $hash_name = $self->{landing_company} . ':potential_loss';
        $redis->hincrbyfloat($hash_name, $_, $potential_loss * @clients, sub { }) foreach @{$self->{global_combinations}};
        $redis->hincrbyfloat($hash_name, $_, $potential_loss,            sub { }) foreach @{$user_combinations};
    }

    my $turnover = -$self->{turnover};
    $hash_name = $self->{landing_company} . ':turnover';
    $redis->hincrbyfloat($hash_name, $_, $turnover, sub { }) foreach @{$turnover_combinations};

    $redis->exec(sub { });
    # It is possible to remove mainloop here; we do not use the response when discarding
    # buys, but it is kept here to avoid complications with pending Redis calls
    $redis->mainloop;

    return;
}

sub add_sells {
    my ($self, @clients) = @_;

    return stats_timed {
        $self->_add_sells(@clients);
    }
    'companylimits.sell' => $self->dd_opts;
}

sub _add_sells {
    my ($self, @clients) = @_;

    my $user_combinations = $self->_get_combinations_with_clients(\&BOM::Transaction::Limits::Combinations::get_user_limit_combinations, \@clients);

    # On sells, potential loss is deducted from open bets. Since exchange rates can vary in different points of time,
    # the potential loss we deduct here may not be the same value that we add during buys. This is something we would
    # need to live with. To mitigate this, we sync the potential loss hash table in Redis with the database in a daily
    # basis.
    # NOTE: potential loss sync to be added later.
    my $contract_data = $self->{contract_data};

    my ($hash_name);
    my $redis = $self->{redis};
    $redis->multi(sub { });

    my $realized_loss = ExchangeRates::CurrencyConverter::in_usd($contract_data->{sell_price} - $contract_data->{buy_price}, $self->{currency});
    $hash_name = $self->{landing_company} . ':realized_loss';
    $redis->hincrbyfloat($hash_name, $_, $realized_loss * @clients, sub { }) foreach @{$self->{global_combinations}};
    $redis->hincrbyfloat($hash_name, $_, $realized_loss,            sub { }) foreach @{$user_combinations};

    unless ($self->_has_no_payout) {
        my $potential_loss =
            ExchangeRates::CurrencyConverter::in_usd($contract_data->{payout_price} - $contract_data->{buy_price}, $self->{currency});
        $hash_name = $self->{landing_company} . ':potential_loss';
        $redis->hincrbyfloat($hash_name, $_, -$potential_loss * @clients, sub { }) foreach @{$self->{global_combinations}};
        $redis->hincrbyfloat($hash_name, $_, -$potential_loss,            sub { }) foreach @{$user_combinations};
    }

    $redis->exec(sub { });
    # It is possible to remove mainloop here; we do not use the response for sells,
    # but it is kept here to avoid complications with pending Redis calls
    $redis->mainloop;

    return;
}

sub _has_no_payout {
    my ($self) = @_;
    # TODO: This is not ideal; we should have a 'has_payout' attribute in contract_categories.yml,
    #       shared by here and also the database table bet.bet_class_without_payout_price
    return $self->{contract_data}->{bet_class} eq 'lookback_option';
}

sub _get_combinations_with_clients {
    my ($self, $combination_func, $clients) = @_;

    my @combinations = map { @{$combination_func->($_->binary_user_id, $self->{attributes})} } @$clients;
    return \@combinations;
}

1;

