package BOM::Product::Contract::Strike;

use Moose;
use namespace::autoclean;

use Readonly;
use Date::Utility;
use POSIX qw( floor );
use Scalar::Util qw(looks_like_number);
use Format::Util::Numbers qw/roundcommon/;

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Product::Static;

with 'MooseX::Role::Validatable';

# Multiply all absolute barriers by this for use in shortcodes
use constant FOREX_BARRIER_MULTIPLIER => 1e6;

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
    isa        => 'underlying_object',
    lazy_build => 1,
    coerce     => 1,
);

sub _build_underlying {
    my $self = shift;

    return create_underlying($self->basis_tick->symbol);
}

has basis_tick => (
    is       => 'ro',
    isa      => 'Postgres::FeedDB::Spot::Tick',
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

sub _build_supplied_type {
    my $self = shift;

    my $barrier_string = $self->supplied_barrier;

    return
          ($barrier_string =~ /^S[+-]?\d+P$/i) ? 'relative'
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
        my $pip_diff    = roundcommon(1, $diff / $self->underlying->pip_size);

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
                message           => "Non-positive barrier [value: $value]",
                message_to_client => [BOM::Product::Static::get_error_mapping()->{NegativeContractBarrier}],
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

    # We'll reapply them on rebuild.
    my $strike = $self;

    return $strike->as_relative if ($strike->supplied_type eq 'relative' or $strike->supplied_type eq 'difference');

    my $sc_version;

    if ($strike->underlying->market->absolute_barrier_multiplier) {
        $sc_version = $strike->as_absolute * FOREX_BARRIER_MULTIPLIER;
    } else {
        # Really?
        $sc_version = floor($strike->as_absolute);
    }

    # Make sure it's an integer
    # There used to be a warning here if it wasn't, but the range finding set it off all the time.
    $sc_version = roundcommon(1, $sc_version);

    return $sc_version;
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

sub strike_string {
    my (undef, $string, $underlying, $bet_type_code) = @_;

    $string /= FOREX_BARRIER_MULTIPLIER
        if ($bet_type_code !~ /^DIGIT/ and $string and looks_like_number($string) and $underlying->market->absolute_barrier_multiplier);

    return $string;
}

sub _proper_value {
    my ($self, $value) = @_;
    return $self->underlying->pipsized_value($value, $self->custom_pipsize);
}

__PACKAGE__->meta->make_immutable;
1;
