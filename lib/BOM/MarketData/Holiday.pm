package BOM::MarketData::Holiday;

use Moose;
use Carp qw(croak);
use Date::Utility;
use List::Util qw(first);
use List::MoreUtils qw(uniq);

use BOM::System::Chronicle;

around BUILDARGS => sub {
    my $orig   = shift;
    my $class  = shift;
    my %params = ref $_[0] ? %{$_[0]} : @_;

    if ($params{calendar} xor $params{recorded_date}) {
        croak "calendar and recorded_date are required when pass in either.";
    }

    return $class->$orig(@_);
};

has [qw(calendar recorded_date)] => (
    is => 'ro',
);

=head2 save

Updates the current holiday calendar with the new inserts.
It trims the calendar by removing holiday before the recorded_date.

=cut

sub save {
    my $self = shift;

    my $cached_holidays = BOM::System::Chronicle::get('holidays', 'holidays');
    my %relevant_holidays = map { $_ => $cached_holidays->{$_} } grep { $_ >= $self->recorded_date->truncate_to_day->epoch } keys %$cached_holidays;
    my $calendar = $self->calendar;

    foreach my $new_holiday (keys %$calendar) {
        my $epoch = Date::Utility->new($new_holiday)->truncate_to_day->epoch;
        unless ($relevant_holidays{$epoch}) {
            $relevant_holidays{$epoch} = $calendar->{$new_holiday};
            next;
        }
        foreach my $new_holiday_desc (keys %{$calendar->{$new_holiday}}) {
            my $new_symbols = $calendar->{$new_holiday}{$new_holiday_desc};
            my $symbols_to_save = [uniq(@{$relevant_holidays{$epoch}{$new_holiday_desc}}, @$new_symbols)];
            $relevant_holidays{$epoch}{$new_holiday_desc} = $symbols_to_save;
        }
    }

    return BOM::System::Chronicle::set('holidays', 'holidays', \%relevant_holidays, $self->recorded_date);
}

sub get_holidays_for {
    my ($symbol, $for_date) = @_;

    my $calendar =
        ($for_date) ? BOM::System::Chronicle::get_for('holidays', 'holidays', $for_date) : BOM::System::Chronicle::get('holidays', 'holidays');
    my %holidays;
    foreach my $date (keys %$calendar) {
        foreach my $holiday_desc (keys %{$calendar->{$date}}) {
            $holidays{$date} = $holiday_desc if (first { $symbol eq $_ } @{$calendar->{$date}{$holiday_desc}});
        }
    }

    return \%holidays;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
