package BOM::CompanyLimits;
use strict;
use warnings;

use BOM::CompanyLimits::Helpers qw(get_redis);
use BOM::CompanyLimits::Combinations;
use BOM::CompanyLimits::LossTypes;
use BOM::CompanyLimits::Stats;
use LandingCompany::Registry;

# TODO: breach implementation to come in 2nd phase...

=head1 NAME

BOM::CompanyLimits

=head1 SYNOPSIS

    my $company_limits = BOM::CompanyLimits->new(
	bet_data => $bet_data,
	currency => $currency,
	landing_company => $landing_company,
    );

    # @clients is list of client objects
    my $result = $company_limits->add_buys(@clients)
    my $result = $company_limits->add_sells(@clients)


    $company_limits->reverse_buys(@clients)

=head1 DESCRIPTION

#TODO: ...

=cut

sub new {
    my ($class, %params) = @_;
    my $self = bless {}, $class;

    $self->_init(%params);

    return $self;
}

sub _init {
    my ($self, %params) = @_;

    my $landing_company = $params{landing_company};

    die "Unsupported landing company $landing_company" unless LandingCompany::Registry::get($landing_company);

    $self->{landing_company} = $landing_company;
    $self->{currency}        = $params{currency};
    $self->{bet_data}        = $params{bet_data};

    # Init gets limit groups from Redis, but is cached so for most cases should be near instant
    my $stat_dat = BOM::CompanyLimits::Stats::stats_start($self, 'init');

    my $attributes = BOM::CompanyLimits::Combinations::get_attributes_from_contract($params{bet_data});
    $self->{global_combinations} = BOM::CompanyLimits::Combinations::get_global_limit_combinations($attributes);
    $self->{attributes}          = $attributes;

    BOM::CompanyLimits::Stats::stats_stop($stat_dat);

    return;
}

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
sub add_buys {
    my ($self, @clients) = @_;

    my $stat_dat = BOM::CompanyLimits::Stats::stats_start($self, 'buys');
    $self->_incr_for_buys(undef, @clients);

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

    # TODO: Check if we should reverse buys?

    $self->_incr_for_buys({reverse => 1}, @clients);
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

    # On sells, potential loss is deducted from open bets
    my $potential_loss = $self->calc_loss('potential_loss');
    $self->_incrby_loss_hash('potential_loss', $self->{global_combinations}, scalar @clients * -$potential_loss,
        $user_combinations, -$potential_loss);

    my $realized_loss = $self->calc_loss('realized_loss');
    $self->_incrby_loss_hash('realized_loss', $self->{global_combinations}, scalar @clients * $realized_loss, $user_combinations, $realized_loss);

    BOM::CompanyLimits::Stats::stats_stop($stat_dat);
    return;
}

sub calc_loss {
    my ($self, $loss_type) = @_;
    my $calc_func = BOM::CompanyLimits::LossTypes::get_calc_loss_func($loss_type);
    return $calc_func->($self->{bet_data}, $self->{currency});
}

sub _incrby_loss_hash {
    my ($self, $loss_type, @incr_pair) = @_;

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
    my ($self, $options, @clients) = @_;
    my $is_reverse = $options->{reverse};

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

    my $potential_loss = $self->calc_loss('potential_loss');
    $potential_loss = -$potential_loss if $is_reverse;
    push @responses,
        $self->_incrby_loss_hash(
        'potential_loss',
        $self->{global_combinations},
        scalar @clients * $potential_loss,
        $user_combinations, $potential_loss
        );

    my $turnover = $self->calc_loss('turnover');
    $turnover = -$turnover if $is_reverse;
    push @responses, $self->_incrby_loss_hash('turnover', $turnover_combinations, $turnover);

    return @responses;
}

1;

