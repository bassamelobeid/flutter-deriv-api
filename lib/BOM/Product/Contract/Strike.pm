package BOM::Product::Contract::Strike;

use Moose;
use namespace::autoclean;

use Carp qw( croak );
use POSIX qw( floor );
use Scalar::Util qw(looks_like_number);
use Readonly;

use Date::Utility;
use BOM::Market::Underlying;
use BOM::Platform::Context qw(localize);
use Format::Util::Numbers qw(roundnear);
use BOM::Product::Types;
use BOM::Utility::ErrorStrings qw( format_error_string );
use feature "state";

with 'MooseX::Role::Validatable';

has supplied_barrier => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has custom_pipsize => (
    is      => 'ro',
    default => undef,
);

has underlying => (
    is         => 'ro',
    isa        => 'bom_underlying_object',
    lazy_build => 1,
    coerce     => 1,
);

sub _build_underlying {
    my $self = shift;

    return BOM::Market::Underlying->new($self->basis_tick->symbol);
}

has basis_tick => (
    is       => 'ro',
    isa      => 'BOM::Market::Data::Tick',
    required => 1,
);

has supplied_type => (
    is         => 'ro',
    isa        => 'Str',
    init_arg   => undef,
    lazy_build => 1,
);

has barrier_type => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has adjustment => (
    is        => 'ro',
    isa       => 'HashRef',
    predicate => 'has_adjustments',
);

sub _build_supplied_type {
    my $self = shift;

    my $barrier_string = $self->supplied_barrier;

    return
          ($barrier_string =~ /^S-?\d+P$/i) ? 'relative'
        : ($barrier_string =~ /^[+-](?:\d+\.?\d{0,12})/ or (looks_like_number($barrier_string) and $barrier_string == 0)) ? 'difference'
        :                                                                                                                   'absolute';
}

sub _build_barrier_type {
    my $self = shift;

    if ($self->supplied_type eq 'absolute') {
        return 'absolute';
    }
    return 'relative';
}

has [qw(as_relative as_absolute)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_as_relative {
    my $self = shift;

    my $relative;

    if ($self->supplied_type eq 'relative') {
        $relative = $self->supplied_barrier;
    } else {
        my $relative_to = $self->basis_tick;
        my $diff        = ($self->supplied_type eq 'absolute') ? $self->supplied_barrier - $relative_to->quote : $self->supplied_barrier;
        my $pip_diff    = roundnear(1, $diff / $self->underlying->pip_size);

        $relative = 'S' . $pip_diff . 'P';
    }

    return $relative;
}

sub _build_as_absolute {
    my $self = shift;

    my $absolute;

    if ($self->supplied_type eq 'absolute') {
        $absolute = $self->_proper_value($self->supplied_barrier);
    } else {
        my $relative_to = $self->basis_tick;
        my $underlying  = $self->underlying;
        my $diff =
            ($self->supplied_type eq 'relative')
            ? $self->pip_difference * $underlying->pip_size
            : $self->supplied_barrier;

        my $value = $relative_to->quote + $diff;
        if ($value <= 0) {
            $self->add_errors({
                severity          => 100,
                message           => format_error_string('Non-positive barrier', value => $value),
                message_to_client => localize('Contract barrier must be positive.'),
            });
            $value = 10 * $underlying->pip_size;
        }

        $absolute = $self->_proper_value($value);
    }

    return $absolute;
}

has as_difference => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_as_difference {
    my $self = shift;

    my $difference;

    if ($self->supplied_type eq 'difference') {
        $difference = $self->supplied_barrier;
    } else {
        my $relative_to = $self->basis_tick;
        my $underlying  = $self->underlying;
        $difference =
            ($self->supplied_type eq 'absolute')
            ? $self->supplied_barrier - $relative_to->quote
            : $self->pip_difference * $underlying->pip_size;
    }
    $difference = $self->_proper_value($difference);
    $difference = '+' . $difference if ($difference >= 0 and $difference !~ /^\+/);

    return $difference;
}

has pip_difference => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_pip_difference {
    my $self = shift;

    my ($pips) = ($self->as_relative =~ /^S(-?\d+)P$/i);

    # This may seem kind of backward, but it works better this way.
    return $pips;
}

has for_shortcode => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_for_shortcode {
    my $self = shift;

    # Shortcode version can't change based on any adjustments added after the fact.
    # We'll reapply them on rebuild.
    my $strike = $self;

    while ($strike->has_adjustments) {
        # Keep on down the rabbit hole until we find the bottom which is unadjusted.
        $strike = $self->adjustment->{prev_obj};
    }

    return $strike->as_relative if ($strike->supplied_type eq 'relative' or $strike->supplied_type eq 'difference');

    my $sc_version;

    if ($strike->underlying->market->absolute_barrier_multiplier) {
        $sc_version = $strike->as_absolute * $self->_forex_barrier_multiplier(Date::Utility->new($self->basis_tick->epoch));
    } else {
        # Really?
        $sc_version = floor($strike->as_absolute);
    }

    # Make sure it's an integer
    # There used to be a warning here if it wasn't, but the range finding set it off all the time.
    $sc_version = roundnear(1, $sc_version);

    return $sc_version;
}

has display_text => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_display_text {
    my $self = shift;

    my $barrier_type = $self->supplied_type;

    my $display_barrier;

    # We don't have the display text to change as well for immutable longcode's sake.
    my $strike = $self;
    while ($strike->has_adjustments) {
        # Keep on down the rabbit hole until we find the bottom which is unadjusted.
        $strike = $self->adjustment->{prev_obj};
    }

    if ($barrier_type eq 'absolute') {
        $display_barrier = $strike->as_absolute;
    } else {
        if (my $pips = $strike->pip_difference) {
            if ($self->underlying->market->name eq 'forex') {
                $display_barrier =
                    ($pips > 0)
                    ? localize('entry spot plus [plural,_1,1 pip, %d pips]',  $pips)
                    : localize('entry spot minus [plural,_1,1 pip, %d pips]', abs $pips);
            } else {
                my $abs_diff = $self->_proper_value(abs $strike->as_difference);
                $display_barrier =
                    ($pips > 0)
                    ? localize('entry spot plus [_1]',  $abs_diff)
                    : localize('entry spot minus [_1]', $abs_diff);
            }
        } else {
            $display_barrier = localize('entry spot');
        }
    }

    return $display_barrier;
}

# Modifiers are limited to simple linear arthimetic adjustments.
# Critic doesn't like eval of expressions.
my %modifiers = (
    'add' => {
        display => '+',
        code    => sub { $_[0] + $_[1]; }
    },
    'subtract' => {
        display => '-',
        code    => sub {
            $_[0] - $_[1];
        }
    },
    'multiply' => {
        display => '*',
        code    => sub {
            $_[0] * $_[1];
        }
    },
    'divide' => {
        display => '/',
        code    => sub {
            $_[0] / $_[1];
        }
    },
);

sub adjust {
    my ($self, $args) = @_;

    croak 'Adjust requires a proper modifier, numeric amount and reason string'
        unless ($args->{reason} and looks_like_number($args->{amount}) and (my $modifier = $modifiers{$args->{modifier}}));

    # We have to do this here to retain barrier type of a contract.
    # This affects long code.
    my $new_supp_barrier;
    if ($self->supplied_type eq 'relative') {
        my $adjusted_barrier = $self->_proper_value($modifier->{code}->($self->as_absolute, $args->{amount}));
        my $relative_to      = $self->basis_tick;
        my $diff             = $adjusted_barrier - $relative_to->quote;
        my $pip_diff         = roundnear(1, $diff / $self->underlying->pip_size);
        $new_supp_barrier = 'S' . $pip_diff . 'P';
    } else {
        $new_supp_barrier = $self->_proper_value($modifier->{code}->($self->as_absolute, $args->{amount}));
    }

    return __PACKAGE__->new(
        underlying       => $self->underlying,
        supplied_barrier => $new_supp_barrier,
        adjustment       => {
            desc     => $modifier->{display} . $args->{amount} . ' -- ' . $args->{reason},
            prev_obj => $self,
        },
        basis_tick => $self->basis_tick,
    );
}

sub list_adjustment_descriptions {
    my $self = shift;

    my @adjustment_descriptions;

    my $strike = $self;

    while ($strike->has_adjustments) {
        push @adjustment_descriptions, $self->adjustment->{desc};
        $strike = $self->adjustment->{prev_obj};
    }

    return @adjustment_descriptions;
}

sub strike_string {
    my ($class, $string, $underlying, $bet_type_code, $when) = @_;

    $when = Date::Utility->new($when);
    # some legacy bet types don't have barriers
    # 0 barriers are NOT difference.
    $string /= $class->_forex_barrier_multiplier($when)
        if ($bet_type_code !~ /^DIGIT/ and $string and looks_like_number($string) and $underlying->market->absolute_barrier_multiplier);

    return $string;
}

sub _proper_value {
    my ($self, $value) = @_;

    my $proper_val =
        ($self->custom_pipsize) ? $self->underlying->pipsized_value($value, $self->custom_pipsize) : $self->underlying->pipsized_value($value);

    return $proper_val;
}

sub _forex_barrier_multiplier {
    my ($self, $when) = @_;

    $when = Date::Utility->new($when);
    # This is the date we increased some of major FX's pip size.
    state $release_date = Date::Utility->new('8-Feb-2015');
    my $multiplier = $when->is_before($release_date) ? 1e4 : 1e6;
    return $multiplier;
}

__PACKAGE__->meta->make_immutable;
1;
