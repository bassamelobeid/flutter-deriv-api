package BOM::Product::Categorizer;

use Moose;
use Syntax::Keyword::Try;
no indirect;

=head1 NAME

BOM::Product::Categorizer - A module that initializes and validates contract input parameters.

=head1 USAGE

    use BOM::Product::Categorizer;

    my $contract_parameters = BOM::Product::Categorizer->new(parameters => {
        bet_type => 'CALL',
        underlying => 'frxUSDJPY',
        duration => '5m',
        barrier => 'S0P',
        currency => 'USD',
        amount_type => 'payout',
        amount => 100,
    })->get();

=cut

use Date::Utility;
use Quant::Framework;
use Finance::Contract::Category;
use Format::Util::Numbers qw(financialrounding);
use Carp qw(croak);
use List::Util qw(any);
use Scalar::Util qw(looks_like_number blessed);
use Scalar::Util::Numeric qw(isint);
use Machine::Epsilon;

use BOM::MarketData qw(create_underlying);
use BOM::Product::Exception;
use LandingCompany::Registry;
use YAML::XS qw(LoadFile);
use BOM::Config::Quants qw(minimum_payout_limit maximum_payout_limit minimum_stake_limit);
use BOM::Config;

my $epsilon                   = machine_epsilon();
my $minimum_multiplier_config = BOM::Config::quants()->{lookback_limits};
my $contract_type_config      = Finance::Contract::Category::get_all_contract_types();

use constant {
    MAX_DURATION => 60 * 60 * 24 * 365 * 2    #2 years in seconds
};

has parameters => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
);

# just to make sure we don't change the input parameters
has _parameters => (
    is       => 'rw',
    init_arg => undef,
);

sub BUILD {
    my $self = shift;

    my %copy = %{$self->parameters};
    $self->_parameters(\%copy);

    my $skip_contract_input_validation = $self->_parameters->{skip_contract_input_validation} || 0;

    $self->_validate_contract_type unless $skip_contract_input_validation;
    $self->_initialize_contract_type;

    # there's no point proceeding if contract type is invalid
    if ($self->_parameters->{bet_type} ne 'INVALID') {

        $self->_initialize_parameters();

        unless ($skip_contract_input_validation) {
            $self->_validate_barrier;
            $self->_validate_stake_min_max;
            $self->_validate_multiplier;
        }

        $self->_initialize_barrier();
        $self->_initialize_other_parameters();
    }

    return;
}

=head2 get

The only public method in this module. This gives you the initialized contract parameters in a hash reference.

=cut

sub get {
    my $self = shift;

    delete $self->_parameters->{build_parameters};
    $self->_parameters->{build_parameters} = {%{$self->_parameters}};

    return $self->_parameters;
}

=head2 _initialize_contract_type

Initialization of contract type

=cut

sub _initialize_contract_type {
    my $self = shift;

    my $params = $self->_parameters;

    # just in case we have someone who doesn't know it needs to be all caps!
    $params->{bet_type} = uc $params->{bet_type};

    my $contract_type = $params->{bet_type};
    my %c_type_config = %{$contract_type_config->{$contract_type}};

    $params->{$_} = $c_type_config{$_} for keys %c_type_config;

    unless ($params->{category}) {
        # not using BOM::Product::Exception here because it is not user defined input
        croak "category not defined for $contract_type";
    }

    $params->{category} = Finance::Contract::Category->new($params->{category});

    return;
}

sub _initialize_parameters {
    my $self = shift;

    my $params = $self->_parameters;

    BOM::Product::Exception->throw(
        error_code => 'MissingRequiredContractParams',
        error_args => ['underlying'],
        details    => {field => 'symbol'},
    ) unless $params->{underlying};

    if (!(blessed $params->{underlying} and $params->{underlying}->isa('Quant::Framework::Underlying'))) {
        $params->{underlying} = create_underlying($params->{underlying});
    }

    # if underlying is not defined, then some settings are default to 'config'
    if ($params->{underlying}->market eq 'config') {
        BOM::Product::Exception->throw(
            error_code => 'InvalidInputAsset',
            details    => {field => 'symbol'},
        );
    }

    # If they gave us a date for start and pricing, then we need to create_underlying using that.
    # date_pricing is set for back-pricing purposes
    if (exists $params->{date_pricing}) {
        $params->{date_pricing} = Date::Utility->new($params->{date_pricing});
        if (not($params->{underlying}->for_date and $params->{underlying}->for_date->is_same_as($params->{date_pricing}))) {
            $params->{underlying} = create_underlying($params->{underlying}->symbol, $params->{date_pricing});
        }
    }

    BOM::Product::Exception->throw(
        error_code => 'MissingRequiredContractParams',
        error_args => ['currency'],
        details    => {field => 'currency'},
    ) unless $params->{currency};

    $params->{payout_currency_type} //= LandingCompany::Registry::get_currency_type($params->{currency});

    if (exists $params->{payout} and exists $params->{stake}) {
        BOM::Product::Exception->throw(
            error_code => 'MissingEither',
            error_args => ['payout', 'stake'],
            details    => {field => 'basis'},
        );
    }

    # these are for the sake of not fixing every unit tests!
    if (exists $params->{stake}) {
        $params->{amount}      = delete $params->{stake};
        $params->{amount_type} = 'stake';
    } elsif (exists $params->{payout}) {
        $params->{amount}      = delete $params->{payout};
        $params->{amount_type} = 'payout';
    }

    # _user_input_stake could come from $contract->build_parameters if make_similar_contract is used
    if (defined $params->{_user_input_stake} and not(defined $params->{amount} and defined $params->{amount_type})) {
        $params->{amount}      = delete $params->{_user_input_stake};
        $params->{amount_type} = 'stake';
    }

    return;
}

sub _initialize_barrier {
    my $self = shift;

    my $params = $self->_parameters;

    # first check if we are expecting any barrier for this contract type
    unless ($params->{has_user_defined_barrier}) {
        # barrier(s) on contracts for sale is built by us so they can be exempted.
        my @available_barriers = ('barrier', 'high_barrier', 'low_barrier');

        # if we build this contract for sale, do some cleanup here.
        delete $params->{$_} for @available_barriers;
        return;
    }

    # double barrier contract
    if ($params->{category}->two_barriers) {
        my ($high_barrier, $low_barrier);
        if (exists $params->{high_barrier} and exists $params->{low_barrier}) {
            ($high_barrier, $low_barrier) = @{$params}{'high_barrier', 'low_barrier'};
        } elsif (exists $params->{supplied_high_barrier} and exists $params->{supplied_low_barrier}) {
            ($high_barrier, $low_barrier) = @{$params}{'supplied_high_barrier', 'supplied_low_barrier'};
        }

        # house keeping
        delete $params->{$_} for qw(high_barrier low_barrier);
        $params->{supplied_high_barrier} = $high_barrier;
        $params->{supplied_low_barrier}  = $low_barrier;
    } else {
        my $barrier = $params->{barrier} // $params->{supplied_barrier};

        # house keeping
        delete $params->{barrier};
        $params->{supplied_barrier} = $barrier;
    }

    return;
}

sub _initialize_other_parameters {
    my $self = shift;

    my $params = $self->_parameters;

    # house keeping.
    delete $params->{shortcode};
    delete $params->{expiry_daily};
    delete $params->{is_intraday};

    # set date start if not given. If we want to price a contract starting now, date_start should never be provided!
    unless ($params->{date_start}) {
        # An undefined or missing date_start implies that we want a bet which starts now.
        $params->{date_start} = Date::Utility->new;
        # Force date_pricing to be similarly set, but make sure we know below that we did this, for speed reasons.
        $params->{pricing_new} = 1;
    } else {
        $params->{date_start} = Date::Utility->new($params->{date_start});
    }

    $params->{pricing_new} = 1
        if $params->{date_pricing} and Date::Utility->new($params->{date_pricing})->is_same_as(Date::Utility->new($params->{date_start}));
    $params->{date_expiry} = Date::Utility->new($params->{date_expiry}) if defined $params->{date_expiry};

    if (defined $params->{duration}) {
        if (my ($tick_count) = $params->{duration} =~ /^([0-9]+)t$/) {
            $params->{tick_expiry} = 1;
            $params->{tick_count}  = $tick_count;
        }
    }

    #TODO: remove this
    $params->{landing_company} //= 'virtual';

    unless (exists $params->{date_start}) {
        BOM::Product::Exception->throw(
            error_code => 'MissingRequiredContractParams',
            error_args => ['date_start'],
            details    => {field => 'date_start'},
        );
    }

    if ($params->{category}->has_user_defined_expiry and defined($params->{date_expiry})) {
        my $duration_in_seconds = $params->{date_expiry}->epoch - $params->{date_start}->epoch;
        if ($duration_in_seconds > MAX_DURATION) {
            BOM::Product::Exception->throw(
                error_code => 'TradingDurationNotAllowed',
                details    => {field => 'duration'});
        }
    }

    if ($params->{category}->has_user_defined_expiry) {
        BOM::Product::Exception->throw(
            error_code => 'DuplicateExpiry',
            error_args => ['duration', 'date_expiry'],
            details    => {field => 'duration'},
        ) if (defined $params->{duration} and defined $params->{date_expiry});
        BOM::Product::Exception->throw(
            error_code => 'MissingEither',
            error_args => ['duration', 'date_expiry'],
            details    => {field => 'duration'},
        ) unless (defined $params->{date_expiry} or defined $params->{duration});
    } elsif ($params->{pricing_new} and (defined $params->{date_expiry} or defined $params->{duration})) {
        BOM::Product::Exception->throw(
            error_code => 'InvalidExpiry',
            error_args => [$params->{bet_type}],
            details    => {field => 'duration'},
        );
    }

    if (not $params->{category}->has_user_defined_expiry and $params->{date_expiry} and $params->{pricing_new}) {
        BOM::Product::Exception->throw(
            error_code => 'InvalidExpiry',
            error_args => [$params->{bet_type}],
            details    => {field => 'duration'},
        );
    }

    # only do this conversion here.
    if ($params->{amount_type}) {
        $params->{amount_type} = '_user_input_stake' if $params->{amount_type} eq 'stake';
        $params->{$params->{amount_type}} = $params->{amount};
    }

    delete $params->{$_} for qw(amount amount_type);

    if (my $orders = delete $params->{limit_order}) {
        $params->{_order} = ref($orders) eq 'ARRAY' ? _to_hashref($orders) : $orders;
    }

    return;
}

=head2 _validate_contract_type

Validation of user defined contract type.

=cut

sub _validate_contract_type {

    my $self = shift;

    my $params = $self->_parameters;

    unless ($params->{bet_type}) {
        BOM::Product::Exception->throw(
            error_code => 'MissingRequiredContractParams',
            error_args => ['bet_type'],
            details    => {field => 'contract_type'},
        );
    }

    $params->{bet_type} = uc $params->{bet_type};

    unless (exists $contract_type_config->{$params->{bet_type}}) {
        $params->{bet_type} = 'INVALID';
    }

    return;

}

=head2 _validate_barrier

Validation of user defined barrier.

=cut

sub _validate_barrier {

    my $self = shift;

    my $params = $self->_parameters;

    # first check if we are expecting any barrier for this contract type
    unless ($params->{has_user_defined_barrier}) {
        # barrier(s) on contracts for sale is built by us so they can be exempted.
        my @available_barriers = ('barrier', 'high_barrier', 'low_barrier');
        if (not $params->{for_sale} and any { $params->{$_} or $params->{'supplied_' . $_} } @available_barriers) {
            BOM::Product::Exception->throw(
                error_code => 'BarrierNotAllowed',
                details    => {field => 'barrier'},
            );
        }
        return;
    }

    # double barrier contract
    if ($params->{category}->two_barriers) {
        my ($high_barrier, $low_barrier);
        if (exists $params->{high_barrier} and exists $params->{low_barrier}) {
            ($high_barrier, $low_barrier) = @{$params}{'high_barrier', 'low_barrier'};
        } elsif (exists $params->{supplied_high_barrier} and exists $params->{supplied_low_barrier}) {
            ($high_barrier, $low_barrier) = @{$params}{'supplied_high_barrier', 'supplied_low_barrier'};
        } else {
            BOM::Product::Exception->throw(
                error_code => 'InvalidBarrierDouble',
                details    => {field => 'barrier'},
            );
        }

        # looks_like_number can be 0 or +0
        if (looks_like_number($high_barrier) and looks_like_number($low_barrier)) {
            my $regex = qr/^(\+|\-)/;
            if (($high_barrier =~ /$regex/ and $low_barrier !~ /$regex/) or ($high_barrier !~ /$regex/ and $low_barrier =~ /$regex/)) {
                # mixed absolute and relative
                BOM::Product::Exception->throw(
                    error_code => 'InvalidBarrierMixedBarrier',
                    details    => {field => 'barrier'},
                );
            } elsif ($high_barrier !~ /$regex/) {
                if ($high_barrier == 0 or $low_barrier == 0) {
                    BOM::Product::Exception->throw(
                        error_code => 'ZeroAbsoluteBarrier',
                        details    => {field => ($high_barrier == 0 ? 'barrier' : 'barrier2')},
                    );
                } elsif (abs($high_barrier - $low_barrier) < $epsilon) {
                    BOM::Product::Exception->throw(
                        error_code => 'SameBarriersNotAllowed',
                        details    => {field => 'barrier'},
                    );
                }
            } elsif ($high_barrier < $low_barrier) {
                BOM::Product::Exception->throw(
                    error_code => 'InvalidHighBarrier',
                    details    => {field => 'barrier'},
                );
            }
        }
    } else {
        if (exists $params->{high_barrier} and exists $params->{low_barrier}) {
            BOM::Product::Exception->throw(
                error_code => 'InvalidBarrierSingle',
                details    => {field => 'barrier'},
            );
        }
        my $barrier = $params->{barrier} // $params->{supplied_barrier};
        if (not defined $barrier) {
            my $error_code = $params->{category}->code eq 'digits' ? 'MissingRequiredDigit' : 'InvalidBarrierSingle';
            BOM::Product::Exception->throw(
                error_code => $error_code,
                details    => {field => 'barrier'},
            );
        } elsif (looks_like_number($barrier) and $params->{category}->has_financial_barrier and $barrier !~ /^(\+|\-)/ and $barrier == 0) {
            BOM::Product::Exception->throw(
                error_code => 'ZeroAbsoluteBarrier',
                details    => {field => 'barrier'},
            );
        }
    }

    return;
}

=head2 _validate_stake_min_max

Validation of stake/payout range

=cut

sub _validate_stake_min_max {

    my $self = shift;

    my $params = $self->_parameters;

    if ($params->{category}->require_basis) {
        BOM::Product::Exception->throw(
            error_code => 'MissingEither',
            error_args => ['payout', 'stake'],
            details    => {field => 'amount'},
        ) if (not(exists $params->{amount_type} and exists $params->{amount}));

        my @allowed = @{$params->{category}->supported_amount_type};
        if (not any { $params->{amount_type} eq $_ } @allowed) {
            my $error_code = scalar(@allowed) > 1 ? 'WrongAmountTypeTwo' : 'WrongAmountTypeOne';
            BOM::Product::Exception->throw(
                error_code => $error_code,
                error_args => \@allowed,
                details    => {field => 'basis'},
            );
        }

        my @limit_args = ($params->{currency}, $params->{landing_company}, $params->{underlying}->market->name, $params->{category}->code);
        my $min_amount = $params->{amount_type} eq 'payout' ? minimum_payout_limit(@limit_args) : minimum_stake_limit(@limit_args);
        BOM::Product::Exception->throw(
            error_code => $params->{amount_type} eq 'stake' ? 'InvalidMinStake' : 'InvalidMinPayout',
            error_args => [financialrounding('price', $params->{currency}, $min_amount)],
            details    => {field => 'amount'})
            if defined $min_amount
            and exists $params->{amount}
            and $params->{amount} < $min_amount
            and not $params->{is_sold};

    } else {
        BOM::Product::Exception->throw(
            error_code => 'InvalidInput',
            error_args => ['basis', $params->{bet_type}],
            details    => {},
        ) if (defined $params->{amount_type} and $params->{amount});
    }

    return;

}

=head2 _validate_multiplier

Validation of minimum multiplier

=cut

sub _validate_multiplier {

    my $self = shift;

    my $params = $self->_parameters;

    if ($params->{category}->require_multiplier) {
        BOM::Product::Exception->throw(
            error_code => 'MissingRequiredContractParams',
            error_args => ['multiplier'],
            details    => {field => 'amount'},
        ) if not defined $params->{multiplier};

        my $minimum_multiplier;
        $minimum_multiplier =
            $minimum_multiplier_config->{min_multiplier}->{$params->{underlying}->symbol} /
            $minimum_multiplier_config->{$params->{payout_currency_type}}
            # re calibrating minimum multiplier should not affect sold contracts.
            if $params->{category}->has_minimum_multiplier && !$params->{is_sold};

        if (defined $minimum_multiplier) {
            # multiplier has non-zero minimum
            if ($params->{multiplier} < $minimum_multiplier) {
                BOM::Product::Exception->throw(
                    error_code => 'MinimumMultiplier',
                    error_args => [financialrounding('price', $params->{currency}, $minimum_multiplier)],
                    details    => {field => 'amount'},
                );
            }
        }
    } else {
        BOM::Product::Exception->throw(
            error_code => 'InvalidInput',
            error_args => ['multiplier', $params->{bet_type}],
            details    => {},
        ) if (defined $params->{multiplier});
    }

    return;

}

sub _to_hashref {
    my $orders = shift;

    my %hash = @$orders;
    foreach my $key (keys %hash) {
        my %inner_hash = @{$hash{$key}};
        $hash{$key} = \%inner_hash;
    }

    return \%hash;
}

has _trading_calendar => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__trading_calendar {
    my $self = shift;

    my $for_date = $self->_parameters->{date_pricing} ? Date::Utility->new($self->_parameters->{date_pricing}) : undef;
    return Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader($for_date), $for_date);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
