package BOM::MarketData::VolSurface::Cutoff;

use Carp;
use Moose;
use DateTime;
use DateTime::TimeZone;
use BOM::Utility::Log4perl qw( get_logger );

use BOM::Market::Types;
use Date::Utility;
use BOM::MarketData::VolSurface::Utils;

=head1 BOM::MarketData::VolSurface::Cutoff coercion

If you'd like to coerce a BOM::MarketData::VolSurface::Cutoff from a String,
the coercion rule is here.

  package MyClass;
  use BOM::MarketData::VolSurface::Cutoff;
  has cutoff => (
    isa => 'BOM::MarketData::VolSurface::Cutoff',
    coerce => 1,
  );

  package main;
  my $instance = MyClass->new(cutoff => 'New York 10:00');

=cut

=head1 ATTRIBUTES

=head2 code

=cut

has code => (
    is       => 'ro',
    isa      => 'bom_cutoff_code',
    required => 1,
);

=head2 code_gmt

=cut

has code_gmt => (
    is         => 'rw',
    isa        => 'bom_cutoff_code',
    lazy_build => 1,
);

has _mytz => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__mytz {
    return DateTime::TimeZone->new(name => shift->timezone);
}

sub _build_code_gmt {
    my $self   = shift;
    my $offset = $self->_mytz->offset_for_datetime(DateTime->now());

    $self->code =~ /^(.+) (\d{1,2}):(\d{2})/;
    my $hour   = $2;
    my $minute = $3;
    if ($offset != 0) {
        $hour -= ($offset / 3600);
    }
    return 'UTC ' . $hour . ':' . $minute;
}

=head2 timezone

=cut

has timezone => (
    is         => 'ro',
    isa        => 'Str',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build_timezone {
    my $self = shift;

    my ($city) = ($self->code =~ /^(.+) \d{1,2}:\d{2}/);

    my %timezone_for = (
        'Bangkok'      => 'Asia/Bangkok',
        'Beijing'      => 'Asia/Shanghai',
        'Bucharest'    => 'Europe/Bucharest',
        'Budapest'     => 'Europe/Budapest',
        'Colombia'     => 'America/Bogota',        # is this correct?
        'Frankfurt'    => 'Europe/Berlin',
        'Hanoi'        => 'Asia/Ho_Chi_Minh',
        'Istanbul'     => 'Europe/Istanbul',
        'Jakarta'      => 'Asia/Jakarta',
        'Kuala Lumpur' => 'Asia/Kuala_Lumpur',
        'London'       => 'Europe/London',
        'Manila'       => 'Asia/Manila',
        'Mexico'       => 'America/Mexico_City',
        'Moscow'       => 'Europe/Moscow',
        'Mumbai'       => 'Asia/Kolkata',
        'New York'     => 'America/New_York',
        # 'PTAX (Ask)'   => 'PTAX (Ask)',            # what is this?
        'Santiago'   => 'America/Santiago',
        'Sao Paulo'  => 'America/Sao_Paulo',
        'Seoul'      => 'Asia/Seoul',
        'Singapore'  => 'Asia/Singapore',
        'Taipei'     => 'Asia/Taipei',
        'Taiwan'     => 'Asia/Taipei',
        'Tel Aviv'   => 'Asia/Jerusalem',
        'Tokyo'      => 'Asia/Tokyo',
        'Warsaw'     => 'Europe/Warsaw',
        'Wellington' => 'Pacific/Auckland',
        'UTC'        => 'UTC',
    );

    # No need to default: anything that's a bom_cutoff_code will have a match.
    return $timezone_for{$city};
}

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;
    my @args  = @_;

    if (scalar @args == 1) {
        @args = (code => $args[0]);
    }

    return $class->$orig(@args);
};

=head1 METHODS

=head2 seconds_to_cutoff_time

Gives the number of BOM trading seconds from a given date
to the next cutoff, given a maturity and an underlying.

=cut

sub seconds_to_cutoff_time {
    my ($self, $args) = @_;

    my $from       = $args->{from}       || croak 'No "from" date given to seconds_to_cutoff_time.';
    my $underlying = $args->{underlying} || croak 'No underlying given to seconds_to_cutoff_time.';
    my $maturity   = $args->{maturity}   || croak 'No maturity given to seconds_to_cutoff_time.';

    # From the given $from date and $maturity, we get the "effective day"
    # on which the cutoff we are looking for falls on.
    # (See effective_date attr of BOM::MarketData::VolSurface for more details
    #  on what this is in practice.)
    #
    # To do so, we first move directly ahead to the effective day,
    # then adjust into the period between subsequent NY1700 (the definition
    # of effective day.
    my $effective_day = $self->_vol_utils->effective_date_for($from->plus_time_interval($maturity . 'd'));

    my $cutoff_date = $self->cutoff_date_for_effective_day($effective_day, $underlying);

    my $seconds = $underlying->calendar->seconds_of_trading_between_epochs($from->epoch, $cutoff_date->epoch);

    return $seconds;
}

has _vol_utils => (
    is       => 'ro',
    isa      => 'BOM::MarketData::VolSurface::Utils',
    init_arg => undef,
    lazy     => 1,
    default  => sub { BOM::MarketData::VolSurface::Utils->new },
);

=head2 cutoff_date_for_effective_day

Will give you the cutoff date for a given effective day. The cutoff date
will always land within the same effective day as given, but may be in
the previous GMT day, as the effective day spans between NY1700s.

=cut

sub cutoff_date_for_effective_day {
    my ($self, $effective_day, $underlying) = @_;

    # We start by truncating the given effective_day back to GMT midnight,
    # then move forward to the cutoff time (in GMT). This is our cutoff date,
    # unless it happens to fall on the next effective day, in which case we move
    # back a day.

    $effective_day = $effective_day->truncate_to_day;

    my $cutoff_offset_from_GMT = $self->_mytz->offset_for_datetime(DateTime->from_epoch(epoch => $effective_day->epoch));    # % 86400;
    my ($hours, $minutes) = ($self->code =~ /(\d{1,2}):(\d{2})$/);
    my $cutoff_date = Date::Utility->new($effective_day->epoch - $cutoff_offset_from_GMT + $hours * 3600 + $minutes * 60);

    my $rollover_date = $self->_vol_utils->NY1700_rollover_date_on($effective_day);

    if ($cutoff_date->epoch > $rollover_date->epoch) {
        $cutoff_date = Date::Utility->new($cutoff_date->epoch - 86400);
    }

    # I put the $attempts login in place as I'm uncomfortable about adding
    # a loop that could theoretically never break.
    my $attempts;
    while (not _valid_cutoff_date($self->_vol_utils->effective_date_for($cutoff_date), $underlying)) {
        get_logger('QUANT')->logdie('Could not find valid cutoff date after 10 attempts, so bailing out!') if ++$attempts > 10;
        $cutoff_date = Date::Utility->new($cutoff_date->epoch + 86400);
    }

    return $cutoff_date;
}

sub _valid_cutoff_date {
    my ($cutoff_date, $underlying) = @_;

    my $calendar = $underlying->calendar;

    return $calendar->trades_on($cutoff_date);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
