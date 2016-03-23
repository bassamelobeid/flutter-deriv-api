package BOM::MarketData::VolSurface::Moneyness;

=head1 NAME

BOM::MarketData::VolSurface::Moneyness

=head1 DESCRIPTION

Base class for strike-based volatility surfaces by moneyness.

=cut

use Moose;
extends 'BOM::MarketData::VolSurface';

use Date::Utility;
use BOM::Platform::Runtime;
use VolSurface::Utils qw(get_delta_for_strike get_strike_for_moneyness);
use BOM::System::Chronicle;

use Try::Tiny;
use Math::Function::Interpolator;
use List::MoreUtils qw(indexes);
use List::Util qw(min first);
use Storable qw( dclone );
use JSON qw(from_json);
use BOM::Utility::Log4perl qw( get_logger );

=head2 for_date

The date for which we wish data

=cut

has for_date => (
    is      => 'ro',
    isa     => 'Maybe[Date::Utility]',
    default => undef,
);

has document => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_document {
    my $self = shift;

    my $document = BOM::System::Chronicle::get('volatility_surfaces', $self->symbol);

    if ($self->for_date and $self->for_date->epoch < Date::Utility->new($document->{date})->epoch) {
        $document = BOM::System::Chronicle::get_for('volatility_surfaces', $self->symbol, $self->for_date->epoch);

        # This works around a problem with Volatility surfaces and negative dates to expiry.
        # We have to use the oldest available surface.. and we don't really know when it
        # was relative to where we are now.. so just say it's from the requested day.
        # We do not allow saving of historical surfaces, so this should be fine.
        $document //= {};
    }

    return $document;
}

sub save {
    my $self = shift;

    #if chronicle does not have this document, first create it because in document_content we will need it
    if (not defined BOM::System::Chronicle::get('volatility_surfaces', $self->symbol)) {
        #Due to some strange coding of retrieval for recorded_date, there MUST be an existing document (even empty)
        #before one can save a document. As a result, upon the very first storage of an instance of the document, we need to create an empty one.
        BOM::System::Chronicle::set('volatility_surfaces', $self->symbol, {});
    }

    return BOM::System::Chronicle::set('volatility_surfaces', $self->symbol, $self->_document_content, $self->recorded_date);
}

sub _document_content {
    my $self = shift;

    my %structure = (
        surfaces       => {$self->cutoff->code => $self->surface},
        date           => $self->recorded_date->datetime_iso8601,
        master_cutoff  => $self->cutoff->code,
        symbol         => $self->symbol,
        type           => $self->type,
        spot_reference => $self->spot_reference,
    );

    return \%structure;
}

=head2 type

Return the surface type

=cut

has '+type' => (
    default => 'moneyness',
);

=head2 extra_sd_vol_spread

sd vol spread is too low, hence add extra vol spread to it.
This amount 3.1 was the optimal spread that we obtained from our backtesting

=cut

has extra_sd_vol_spread => (
    is      => 'ro',
    isa     => 'Num',
    default => 3.1 / 100,
);

has atm_spread_point => (
    is      => 'ro',
    isa     => 'Num',
    default => 100,
);

=head2 moneynesses

Returns the moneyness points on the surface

=cut

has moneynesses => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy_build => 1,
);

sub _build_moneynesses {
    my $self = shift;
    return $self->smile_points;
}

=head2 corresponding_deltas

Stores the corresponding moneyness smile in terms on delta.
This is aimed to reduced computation time.

=cut

has corresponding_deltas => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

=head2 spot_reference

Get the spot reference used to calculate the surface.
We should always use reference spot of the surface for any moneyness-related vol calculation

=cut

has spot_reference => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_spot_reference {
    my $self = shift;

    return $self->document->{spot_reference};
}

=head2 get_volatility

USAGE:

  my $vol = $s->get_volatility({moneyness => 96, days => 7});
  my $vol = $s->get_volatility({strike => $bet->barrier, tenor => '1M'});
  my $vol = $s->get_volatility({moneyness => 90, expiry_date => Date::Utility->new});

=cut

sub get_volatility {
    my ($self, $args) = @_;

    if (scalar(grep { defined $args->{$_} } qw(delta moneyness strike)) != 1) {
        get_logger('QUANT')->logdie("Must pass exactly one of [delta, moneyness, strike] to get_volatility.");
    }

    $args->{days} =
        ($self->underlying->submarket->name eq 'random_daily')
        ? 2 / 86400
        : $self->_convert_expiry_to_day($args);

    my $vol;
    if ($args->{delta}) {

        # we are handling delta seperately because it involves
        # a lot more steps to calculate vol for a delta point
        # on a moneyness surface
        $vol = $self->_calculate_vol_for_delta({
            delta => $args->{delta},
            days  => $args->{days},
        });
    } else {
        my $sought_point =
              $args->{strike}
            ? $args->{strike} / $self->spot_reference * 100
            : $args->{moneyness};

        my $calc_args = {
            sought_point => $sought_point,
            days         => $args->{days}};
        $vol = $self->SUPER::get_volatility($calc_args);
    }

    return $vol;
}

=head2 interpolate

This is how you could interpolate across smile.
This uses the default interpolation method of the surface.

    $surface->interpolate({smile => $smile, sought_point => $sought_point});
=cut

sub interpolate {
    my ($self, $args) = @_;

    my $method = keys %{$args->{smile}} < 5 ? 'quadratic' : 'cubic';
    my $interpolator = Math::Function::Interpolator->new(points => $args->{smile});

    return $interpolator->$method($args->{sought_point});
}

=head2 set_corresponding_deltas

Since we allow getting volatility for a particular delta point
on a moneyness surface, here is how you could cache it.

    $moneyness->set_corresponding_deltas(7, {25 => 0.1, 50 => 0.2, 75 => 0.3});

=cut

sub set_corresponding_deltas {
    my ($self, $days, $smile) = @_;

    my $deltas = $self->corresponding_deltas;
    $deltas->{$days} = $smile;

    return;
}

# rr and bf only make sense in delta term. Here we convert the smile to a delta smile.
override get_market_rr_bf => sub {
    my ($self, $day) = @_;

    my %smile = map { $_ => $self->_calculate_vol_for_delta({delta => $_, days => $day}) } qw(25 50 75);

    return $self->get_rr_bf_for_smile(\%smile);
};

## PRIVATE ##

sub _calculate_vol_for_delta {
    my ($self, $args) = @_;

    my $delta = $args->{delta};
    my $days  = $args->{days};
    my $smile;

    if (exists $self->corresponding_deltas->{$days}) {
        $smile = $self->corresponding_deltas->{$days};
    } else {
        $smile = $self->_convert_moneyness_smile_to_delta($days);
        $self->set_corresponding_deltas($days, $smile);
    }

    return $smile->{$delta}
        ? $smile->{$delta}
        : $self->_interpolate_delta({
            smile        => $smile,
            sought_point => $delta
        });
}

sub _interpolate_delta {
    my ($self, $args) = @_;

    my %smile = %{$args->{smile}};

    get_logger('QUANT')->logcroak('minimum of three points on a smile')
        if keys %smile < 3;

    my @sorted = sort { $a <=> $b } keys %smile;
    my %new_smile =
        map { $_ => $smile{$_} } grep { $_ > 1 and $_ < 99 } @sorted;

    if (keys %new_smile < 5) {
        my @diff = map { abs($_ - 50) } @sorted;
        my $atm_index = indexes { min(@diff) == abs($_ - 50) } @sorted;
        %new_smile =
            map { $sorted[$_] => $smile{$sorted[$_]} } ($atm_index - 1 .. $atm_index + 1);
    }

    $args->{smile} = \%new_smile;

    return $self->interpolate($args);
}

sub _convert_moneyness_smile_to_delta {
    my ($self, $days) = @_;

    my $moneyness_smile = $self->get_smile($days);

    my %strikes =
        map { get_strike_for_moneyness({moneyness => $_ / 100, spot => $self->spot_reference,}) => $moneyness_smile->{$_} } keys %$moneyness_smile;
    my %deltas;
    foreach my $strike (keys %strikes) {
        my $vol   = $strikes{$strike};
        my $delta = $self->_convert_strike_to_delta({
            strike => $strike,
            days   => $days,
            vol    => $vol
        });
        $deltas{$delta} = $vol;
    }

    return \%deltas,;
}

sub _convert_strike_to_delta {
    my ($self, $args) = @_;
    my ($days, $vol, $strike) = @{$args}{'days', 'vol', 'strike'};
    my $tiy        = $days / 365;
    my $underlying = $self->underlying;

    return 100 * get_delta_for_strike({
        strike           => $strike,
        atm_vol          => $vol,
        t                => $tiy,
        spot             => $self->spot_reference,
        r_rate           => $underlying->interest_rate_for($tiy),
        q_rate           => $underlying->dividend_rate_for($tiy),
        premium_adjusted => $underlying->market_convention->{delta_premium_adjusted},
    });
}

sub _extrapolate_smile_down {
    my $self = shift;

    my $first_market_point = $self->original_term_for_smile->[0];

    return $self->surface->{$first_market_point}->{smile};
}

=head2 clone

USAGE:

  my $clone = $s->clone({
    surface => $my_new_surface,
    cutoff  => $my_new_cutoff,
  });

Returns a new BOM::MarketData::VolSurface instance. You can pass overrides to override an attribute value as it is on the original surface.

=cut

sub clone {
    my ($self, $args) = @_;

    my %clone_args;
    %clone_args = %$args if $args;

    $clone_args{spot_reference} = $self->spot_reference
        if (not exists $clone_args{spot_reference});
    $clone_args{underlying} = $self->underlying
        if (not exists $clone_args{underlying});
    $clone_args{cutoff} = $self->cutoff
        if (not exists $clone_args{cutoff});

    if (not exists $clone_args{surface}) {
        my $orig_surface = dclone($self->surface);
        my %surface_to_clone = map { $_ => $orig_surface->{$_} } @{$self->original_term_for_smile};
        $clone_args{surface} = \%surface_to_clone;
    }

    $clone_args{recorded_date} = $self->recorded_date
        if (not exists $clone_args{recorded_date});
    $clone_args{print_precision} = $self->print_precision
        if (not exists $clone_args{print_precision});
    $clone_args{original_term} = dclone($self->original_term)
        if (not exists $clone_args{original_term});

    return $self->meta->name->new(\%clone_args);
}

=head2 cutoff

default to closing on the underlying.

=cut

has cutoff => (
    is         => 'ro',
    isa        => 'bom_cutoff_helper',
    lazy_build => 1,
    coerce     => 1,
);

sub _build_cutoff {
    my $self = shift;

    my $date = $self->for_date ? $self->for_date : Date::Utility->new;

    return BOM::MarketData::VolSurface::Cutoff->new('UTC ' . $self->underlying->exchange->standard_closing_on($date)->time_hhmm);
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
