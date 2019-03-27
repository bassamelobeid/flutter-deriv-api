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
    return 0.05;    # a fixed 5% regardless of market though we only offer forex now.
};

# we do not want to apply this for MultiBarrier.
override apply_market_inefficient_limit => sub {
    return 0;
};

has trading_period_start => (
    is       => 'ro',
    required => 1,
);

=head2 predefined_contracts

Some landing company requires script contract offerings in which we will have pre-set
contract barriers, start and expiry time. As of now, this is only applicable to multibarrier.

=cut

has predefined_contracts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_predefined_contracts {
    my $self = shift;

    my $predefined_barriers = get_predefined_barriers_by_contract_category($self->underlying->symbol, $self->underlying->for_date);
    my $windows_for_category = $predefined_barriers->{$self->category->code};

    #no barriers for this category
    return {} unless $windows_for_category;

    my $barriers = $windows_for_category->{$self->trading_period_start . '-' . $self->date_expiry->epoch};
    #no barriers for this trading window
    return {} unless $barriers;

    return {
        available_barriers => $barriers->{available_barriers},
        expired_barriers   => $self->category->is_path_dependent
        ? get_expired_barriers(
            $self->underlying,
            $barriers->{available_barriers},
            {
                date_start  => {epoch => $self->trading_period_start},
                date_expiry => {epoch => $self->date_expiry->epoch}})
        : []};
}

around _validate_start_and_expiry_date => sub {
    my $orig = shift;
    my $self = shift;

    return if $self->$orig(@_);

    # for multi-barrier, we only allow pre-defined start and expiry times.
    unless (%{$self->predefined_contracts}) {
        return {
            message => 'Invalid contract expiry[' . $self->date_expiry->datetime . '] for multi-barrier at ' . $self->date_pricing->datetime . '.',
            message_to_client => [$ERROR_MAPPING->{InvalidExpiryTime}],
            details           => {field => defined($self->duration) ? 'duration' : 'date_expiry'},
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
            my %field_for = (
                'high_barrier' => 'barrier',
                'low_barrier'  => 'barrier2',
                'barrier'      => 'barrier',
            );
            return {
                message           => 'barrier should be absolute',
                message_to_client => [$ERROR_MAPPING->{PredefinedNeedAbsoluteBarrier}],
                details           => {field => $field_for{$barrier}},
            };
        }
    }

    return;
};

sub _subvalidate_single_barrier {
    my $self = shift;

    my $info               = $self->predefined_contracts;
    my @available_barriers = @{$info->{available_barriers} // []};
    my %expired_barriers   = map { $_ => 1 } @{$info->{expired_barriers} // []};
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
            details           => {field => 'barrier'},
        };
    }

    return;
}

sub _subvalidate_double_barrier {
    my $self = shift;

    my $info               = $self->predefined_contracts;
    my @available_barriers = @{$info->{available_barriers} // []};
    my @expired_barriers   = @{$info->{expired_barriers} // []};

    my $epsilon = 1e-10;
    my @filtered;
    foreach my $pair (@available_barriers) {
        # checks for expired barriers and exclude them from available barriers.
        my $barrier_expired = first { abs($pair->[0] - $_->[0]) < $epsilon and abs($pair->[1] - $_->[1]) < $epsilon } @expired_barriers;
        next if $barrier_expired;
        push @filtered, $pair;
    }

    my $matched_barrier =
        first { abs($self->low_barrier->as_absolute - $_->[0]) < $epsilon and abs($self->high_barrier->as_absolute - $_->[1]) < $epsilon } @filtered;
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
            details           => {field => 'barrier'},
        };
    }

    return;
}

override '_check_intraday_engine_compatibility' => sub {
    my $self = shift;

    my $engine_name =
        $self->market->name eq 'indices' ? 'BOM::Product::Pricing::Engine::Intraday::Index' : 'BOM::Product::Pricing::Engine::Intraday::Forex';

    return $engine_name->get_compatible('multi_barrier', $self->metadata);
};

1;
