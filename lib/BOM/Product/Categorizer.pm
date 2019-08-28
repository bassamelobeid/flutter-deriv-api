package BOM::Product::Categorizer;

use Moose;
use Try::Tiny;
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
use Carp qw(croak);
use List::Util qw(any);
use Scalar::Util qw(looks_like_number blessed);
use Scalar::Util::Numeric qw(isint);
use Machine::Epsilon;

use BOM::MarketData qw(create_underlying);
use BOM::Product::Exception;
use LandingCompany::Registry;
use YAML::XS qw(LoadFile);

my $epsilon                   = machine_epsilon();
my $minimum_multiplier_config = LoadFile('/home/git/regentmarkets/bom/config/files/lookback_minimum_multiplier.yml');

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

    return;
}

=head2 get

The only public method in this module. This gives you the initialized contract parameters in a hash reference.

=cut

sub get {
    my $self = shift;

    $self->_initialize_contract_type();

    # there's no point proceeding if contract type is invalid
    if ($self->_parameters->{bet_type} ne 'INVALID') {
        $self->_initialize_barrier();
        $self->_initialize_underlying();
        $self->_initialize_other_parameters();
    }

    delete $self->_parameters->{build_parameters};
    $self->_parameters->{build_parameters} = {%{$self->_parameters}};

    return $self->_parameters;
}

sub _initialize_contract_type {
    my $self = shift;

    my $params = $self->_parameters;

    unless ($params->{bet_type}) {
        BOM::Product::Exception->throw(
            error_code => 'MissingRequiredContractParams',
            error_args => ['bet_type'],
            details    => {field => 'contract_type'},
        );
    }

    # just in case we have someone who doesn't know it needs to be all caps!
    $params->{bet_type} = uc $params->{bet_type};
    my $contract_type_config = Finance::Contract::Category::get_all_contract_types();

    unless (exists $contract_type_config->{$params->{bet_type}}) {
        $params->{bet_type} = 'INVALID';
        return;
    }

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

sub _initialize_barrier {
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
                        error_code => 'InvalidHighBarrier',
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

        # house keeping
        delete $params->{$_} for qw(high_barrier low_barrier);
        $params->{supplied_high_barrier} = $high_barrier;
        $params->{supplied_low_barrier}  = $low_barrier;
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

        # house keeping
        delete $params->{barrier};
        $params->{supplied_barrier} = $barrier;
    }

    return;
}

sub _initialize_underlying {
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

    return;
}

sub _initialize_other_parameters {
    my $self = shift;

    my $params = $self->_parameters;

    # house keeping.
    delete $params->{shortcode};
    delete $params->{expiry_daily};
    delete $params->{is_intraday};

    BOM::Product::Exception->throw(
        error_code => 'MissingRequiredContractParams',
        error_args => ['currency'],
        details    => {field => 'currency'},
    ) unless $params->{currency};

    # set date start if not given. If we want to price a contract starting now, date_start should never be provided!
    unless ($params->{date_start}) {
        # An undefined or missing date_start implies that we want a bet which starts now.
        $params->{date_start} = Date::Utility->new;
        # Force date_pricing to be similarly set, but make sure we know below that we did this, for speed reasons.
        $params->{pricing_new} = 1;
    } else {
        $params->{date_start} = Date::Utility->new($params->{date_start});
    }

    # if both are present, we will throw an error
    if (exists $params->{duration} and exists $params->{date_expiry}) {
        BOM::Product::Exception->throw(
            error_code => 'MissingEither',
            error_args => ['duration', 'date_expiry'],
            details    => {field => ''},
        );
    }

    if (defined $params->{date_expiry}) {
        # to support legacy shortcode where expiry date is date string in dd-mmm-yy format
        if (Date::Utility::is_ddmmmyy($params->{date_expiry})) {
            my $exchange = $params->{underlying}->exchange;
            $params->{date_expiry} = $self->_trading_calendar->closing_on($exchange, Date::Utility->new($params->{date_expiry}));
            # contract bought expires on a non-trading day
            unless ($params->{date_expiry}) {
                BOM::Product::Exception->throw(
                    error_code => 'TradingDayExpiry',
                    details    => {field => $params->{duration} ? 'duration' : 'date_expiry'},
                );
            }
        } else {
            $params->{date_expiry} = Date::Utility->new($params->{date_expiry});
        }
    }

    #TODO: remove this
    $params->{landing_company} //= 'svg';
    $params->{payout_currency_type} //= LandingCompany::Registry::get_currency_type($params->{currency});

    if (defined $params->{duration}) {
        my $duration = delete $params->{duration};
        if ($duration !~ /[0-9]+(t|m|d|s|h)/) {
            BOM::Product::Exception->throw(
                error_code => 'TradingDurationNotAllowed',
                details    => {field => 'duration'},
            );
        } else {
            # sanity check for duration. Date::Utility throws exception if you're trying
            # to create an object that's too ridiculous far in the future.

            my $expected_feed_frequency = $params->{underlying}->generation_interval->seconds;
            # defaults to 2-second if not specified
            $expected_feed_frequency = 2 if $expected_feed_frequency == 0;
            try {
                my ($duration_amount, $duration_unit) = $duration =~ /([0-9]+)(t|m|d|s|h)/;
                my $interval = $duration;
                $interval = $duration_amount * $expected_feed_frequency if $duration_unit eq 't';
                $params->{date_start}->plus_time_interval($interval);
            }
            catch {
                BOM::Product::Exception->throw(
                    error_code => 'TradingDurationNotAllowed',
                    details    => {field => 'duration'});
            };
            if (my ($tick_count) = $duration =~ /^([0-9]+)t$/) {
                $params->{tick_expiry} = 1;
                $params->{tick_count}  = $tick_count;
                $params->{date_expiry} = $params->{date_start}->plus_time_interval($expected_feed_frequency * $params->{tick_count});
            } else {
                my $underlying  = $params->{underlying};
                my $start_epoch = $params->{date_start};
                $params->{date_expiry} = $start_epoch->plus_time_interval($duration);

                if ($duration =~ /d$/) {
                    # Daily bet expires at the end of day, so here you go
                    if (my $closing = $self->_trading_calendar->closing_on($underlying->exchange, $params->{date_expiry})) {
                        $params->{date_expiry} = $closing;
                    } else {
                        my $regular_day = $self->_trading_calendar->regular_trading_day_after($underlying->exchange, $params->{date_expiry});
                        my $regular_close = $self->_trading_calendar->closing_on($underlying->exchange, $regular_day);
                        $params->{date_expiry} = Date::Utility->new($params->{date_expiry}->date_yyyymmdd . ' ' . $regular_close->time_hhmmss);
                    }
                }
            }
        }
    }

    unless (exists $params->{date_start}) {
        BOM::Product::Exception->throw(
            error_code => 'MissingRequiredContractParams',
            error_args => ['date_start'],
            details    => {field => 'date_start'},
        );
    }

    if ($params->{category}->has_user_defined_expiry and not $params->{date_expiry}) {
        BOM::Product::Exception->throw(
            error_code => 'MissingEither',
            error_args => ['duration', 'date_expiry'],
            details    => {field => 'duration'},
        );
    }

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
    } elsif (exists $params->{multiplier}) {
        $params->{amount}      = delete $params->{multiplier};
        $params->{amount_type} = 'multiplier';
    } elsif (exists $params->{payout}) {
        $params->{amount}      = delete $params->{payout};
        $params->{amount_type} = 'payout';
    }

    unless (exists $params->{amount_type} and exists $params->{amount}) {
        my $is_lookback = $params->{category}->code eq 'lookback';
        my $error_code  = $is_lookback ? 'MissingRequiredContractParams' : 'MissingEither';
        my $error_args  = $is_lookback ? ['multiplier'] : ['payout', 'stake'];
        BOM::Product::Exception->throw(
            error_code => $error_code,
            error_args => $error_args,
            details    => {field => 'amount'},
        );
    }

    my @allowed = @{$params->{category}->supported_amount_type};
    if (not any { $params->{amount_type} eq $_ } @allowed) {
        my $error_code = scalar(@allowed) > 1 ? 'WrongAmountTypeTwo' : 'WrongAmountTypeOne';
        BOM::Product::Exception->throw(
            error_code => $error_code,
            error_args => \@allowed,
            details    => {field => 'basis'},
        );
    }

    my $minimum_multiplier;
    $minimum_multiplier = $minimum_multiplier_config->{$params->{underlying}->symbol} / $minimum_multiplier_config->{$params->{payout_currency_type}}
        if $params->{category}->has_minimum_multiplier;

    if (defined $minimum_multiplier) {
        # multiplier has non-zero minimum
        if ($params->{amount} < $minimum_multiplier) {
            BOM::Product::Exception->throw(
                error_code => 'MinimumMultiplier',
                error_args => [$minimum_multiplier],
                details    => {field => 'amount'},
            );
        }
    } elsif ($params->{amount} <= 0) {
        BOM::Product::Exception->throw(
            error_code => 'InvalidStake',
            details    => {field => 'amount'});
    }

    # only do this conversion here.
    $params->{amount_type} = 'ask_price' if $params->{amount_type} eq 'stake';
    $params->{$params->{amount_type}} = $params->{amount};
    delete $params->{$_} for qw(amount amount_type);

    return;
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
