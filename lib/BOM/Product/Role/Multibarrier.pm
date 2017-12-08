package BOM::Product::Role::Multibarrier;

use Moose::Role;
use List::Util qw(first);
use Data::Dumper;

use BOM::Platform::RiskProfile;
use BOM::Product::Static;
use BOM::Product::Contract::PredefinedParameters qw(get_predefined_barriers_by_contract_category get_expired_barriers);

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

override is_parameters_predefined => sub {
    return 1;
};

override disable_trading_at_quiet_period => sub {
    return 0;
};

override _build_otm_threshold => sub {
    return 0.05;    # a fixed 5% for japan regardless of market though we only offer forex now.
};

# we do not want to apply this for Japan.
override apply_market_inefficient_limit => sub {
    return 0;
};

has trading_window_start => (
    is       => 'ro',
    required => 1,
);

has landing_company => (
    is      => 'ro',
    default => 'japan',
);

=head2 predefined_contracts

Some landing company requires script contract offerings in which we will have pre-set
contract barriers, start and expiry time. As of now, this is only applicable for japan.

=cut

has predefined_contracts => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_predefined_contracts {
    my $self = shift;

    my $predefined_barriers = get_predefined_barriers_by_contract_category($self->underlying->symbol, $self->underlying->for_date);
    my $windows_for_category = $predefined_barriers->{$self->category->code};

    return {} unless $windows_for_category;

    my $is_path_dependent = $self->category->is_path_dependent;
    my %info;
    foreach my $key (keys %$windows_for_category) {
        my $data = $windows_for_category->{$key};
        my ($start_epoch, $expiry_epoch) = split '-', $key;
        my $tp = {
            date_start  => {epoch => $start_epoch},
            date_expiry => {epoch => $expiry_epoch},
        };
        my $expired_barriers = $is_path_dependent ? get_expired_barriers($self->underlying, $data->{available_barriers}, $tp) : [];
        push @{$info{$expiry_epoch}{available_barriers}}, @{$data->{available_barriers}};
        push @{$info{$expiry_epoch}{expired_barriers}},   @$expired_barriers;
    }

    return \%info;
}

override risk_profile => sub {
    my $self = shift;

    return BOM::Platform::RiskProfile->new(
        underlying                     => $self->underlying,
        contract_category              => $self->category_code,
        expiry_type                    => $self->expiry_type,
        start_type                     => ($self->is_forward_starting ? 'forward' : 'spot'),
        currency                       => $self->currency,
        barrier_category               => $self->barrier_category,
        landing_company                => $self->landing_company,
        symbol                         => $self->underlying->symbol,
        market_name                    => $self->underlying->market->name,
        submarket_name                 => $self->underlying->submarket->name,
        underlying_risk_profile        => $self->underlying->risk_profile,
        underlying_risk_profile_setter => $self->underlying->risk_profile_setter,
    );
};

around _validate_start_and_expiry_date => sub {
    my $orig = shift;
    my $self = shift;

    return if $self->$orig(@_);

    return unless %{$self->predefined_contracts};

    # for multi-barrier, we only allow pre-defined start and expiry times.
    my $available_contracts = $self->predefined_contracts;
    my $expiry_epoch        = $self->date_expiry->epoch;
    if (not $available_contracts->{$expiry_epoch}) {
        return {
            message => 'Invalid contract expiry[' . $self->date_expiry->datetime . '] for multi-barrier at ' . $self->date_pricing->datetime . '.',
            message_to_client => [$ERROR_MAPPING->{InvalidExpiryTime}],
        };
    }

    return;
};

around _validate_barrier => sub {
    my $orig = shift;
    my $self = shift;

    # if normal barrier validation fails, don't bother to validate further.
    if (my $err = $self->$orig(@_)) {
        return $err;
    }

    return if $self->for_sale;

    return $self->_subvalidate_double_barrier() if ($self->two_barriers);
    return $self->_subvalidate_single_barrier();
};

override _validate_barrier_type => sub {
    my $self = shift;

    foreach my $barrier ($self->two_barriers ? ('high_barrier', 'low_barrier') : ('barrier')) {
        if (defined $self->$barrier and $self->$barrier->barrier_type ne 'absolute') {
            return {
                message           => 'barrier should be absolute',
                message_to_client => [$ERROR_MAPPING->{PredefinedNeedAbsoluteBarrier}],
            };
        }
    }

    return;
};

sub _subvalidate_single_barrier {
    my $self = shift;

    if (%{$self->predefined_contracts} and my $info = $self->predefined_contracts->{$self->date_expiry->epoch}) {
        my @available_barriers = @{$info->{available_barriers} // []};
        my %expired_barriers = map { $_ => 1 } @{$info->{expired_barriers} // []};
        # barriers are pipsized, make them numbers.
        my $epsilon = 1e-10;
        my $matched_barrier = first { abs($self->barrier->as_absolute - $_) < $epsilon } grep { not $expired_barriers{$_} } @available_barriers;

        unless ($matched_barrier) {

            return {
                message => 'Invalid barrier['
                    . $self->barrier->as_absolute
                    . '] for expiry ['
                    . $self->date_expiry->datetime
                    . '] and contract type['
                    . $self->code
                    . '] for multi-barrier at '
                    . $self->date_pricing->datetime . '.',
                message_to_client => [$ERROR_MAPPING->{InvalidBarrier}],
            };
        }
    }

    return;
}

sub _subvalidate_double_barrier {
    my $self = shift;

    if (%{$self->predefined_contracts} and my $info = $self->predefined_contracts->{$self->date_expiry->epoch}) {
        my @available_barriers = @{$info->{available_barriers} // []};
        my @expired_barriers   = @{$info->{expired_barriers}   // []};

        my $epsilon = 1e-10;
        my @filtered;
        foreach my $pair (@available_barriers) {
            # checks for expired barriers and exclude them from available barriers.
            my $barrier_expired = first { abs($pair->[0] - $_->[0]) < $epsilon and abs($pair->[1] - $_->[1]) < $epsilon } @expired_barriers;
            next if $barrier_expired;
            push @filtered, $pair;
        }

        my $matched_barrier =
            first { abs($self->low_barrier->as_absolute - $_->[0]) < $epsilon and abs($self->high_barrier->as_absolute - $_->[1]) < $epsilon }
        @filtered;
        unless ($matched_barrier) {

            return {
                message => 'Invalid barriers['
                    . $self->low_barrier->as_absolute . ','
                    . $self->high_barrier->as_absolute
                    . '] for expiry ['
                    . $self->date_expiry->datetime
                    . '] and contract type['
                    . $self->code
                    . '] for multi-barrier at '
                    . $self->date_pricing->datetime . '.',
                message_to_client => [$ERROR_MAPPING->{InvalidBarrier}],
            };
        }
    }

    return;
}

# Compose a string containing all the pricing info that needed to be log for Japan
sub japan_pricing_info {
    my ($self, $trading_window_start, $opposite_contract) = @_;

    my $bid_price = $self->payout - $opposite_contract->ask_price;
    my @pricing_info = ($self->shortcode, $trading_window_start, $self->ask_price, $bid_price, $self->_date_pricing_milliseconds);

    my $extra = $self->extra_info('string');
    my $pricing_info = join ',', @pricing_info, $extra;

    return "[JPLOG]," . $pricing_info . "\n";
}

override '_check_intraday_engine_compatibility' => sub {
    my $self = shift;

    my $engine_name =
        $self->market->name eq 'indices' ? 'BOM::Product::Pricing::Engine::Intraday::Index' : 'BOM::Product::Pricing::Engine::Intraday::Forex';

    return $engine_name->get_compatible('multi_barrier', $self->metadata);
};

1;
