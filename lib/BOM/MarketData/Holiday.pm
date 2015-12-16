package BOM::MarketData::Holiday;

use Moose;
use Carp qw(croak);
use Date::Utility;

use BOM::System::Chronicle;

around BUILDARGS => sub {
    my $orig   = shift;
    my $class  = shift;
    my %params = ref $_[0] ? %{$_[0]} : $_[0];

    my ($a, $b, $c) = map { $params{$_} } qw(date affected_symbols description);
    if (($a && !$b && !$c) || (!$a && $b && !$c) || (!$a && !$b && $c)) {
        croak "date, affected_symbols and description are required when pass in either.";
    }

    return $class->$orig(@_);
};

has recorded_date => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_recorded_date {
    return Date::Utility->new;
}

has [qw(affected_symbols date description)] => (
    is => 'ro',
);

sub save {
    my $self = shift;

    my $holiday_document = {
        $self->date->truncate_to_day->epoch => {
            description      => $self->description,
            affected_symbols => $self->affected_symbols,
        },
    };

    return BOM::System::Chronicle::set('holidays', 'holidays', $holiday_document);
}

sub get_holidays_for {
    my ($symbol, $for_date) = @_;

    my %holidays;
    my $calendar =
        ($for_date) ? BOM::System::Chronicle::get_for('holidays', 'holidays', $for_date) : BOM::System::Chronicle::get('holidays', 'holidays');
    foreach my $holiday (keys %$calendar) {
        my $affected_symbols = $calendar->{$holiday}->{affected_symbols};
        if (first { $symbol eq $_ } @$affected_symbols) {
            $holidays{$holiday} = $calendar->{$holiday}->{description};
        }
    }

    return \%holidays;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
