package BOM::MarketData::PartialTrading;

use Moose;
use List::MoreUtils qw(uniq);
use List::Util qw(first);
use Date::Utility;
use Carp qw(croak);

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

=head2 type

The type of partial trading:
- early close
- late open

=cut

has type => (
    is       => 'ro',
    required => 1,
);

has [qw(calendar recorded_date)] => (
    is => 'ro',
);

sub save {
    my $self = shift;

    my $cached_data = BOM::System::Chronicle::get('partial_trading', $self->type);
    my $recorded_epoch = $self->recorded_date->truncate_to_day->epoch;
    my %relevant_dates =
        map { $_ => $cached_data->{$_} }
        grep { $_ >= $recorded_epoch } keys %$cached_data;
    my %calendar = map { Date::Utility->new($_)->truncate_to_day->epoch => $self->calendar->{$_} } keys %{$self->calendar};

    foreach my $epoch (keys %calendar) {
        unless ($relevant_dates{$epoch}) {
            $relevant_dates{$epoch} = $calendar{$epoch};
            next;
        }
        foreach my $close_time (keys %{$calendar{$epoch}}) {
            my @symbols_to_save = uniq(@{$relevant_dates{$epoch}{$close_time}}, @{$calendar{$epoch}{$close_time}});
            $relevant_dates{$epoch}{$close_time} = \@symbols_to_save;
        }
    }

    return BOM::System::Chronicle::set('partial_trading', $self->type, \%relevant_dates);
}

sub get_partial_trading_for {
    my ($type, $symbol, $for_date) = @_;

    my $cached =
        $for_date
        ? BOM::System::Chronicle::get_for('partial_trading', $type, $for_date)
        : BOM::System::Chronicle::get('partial_trading', $type);
    my %early_closes;
    foreach my $epoch (keys %$cached) {
        foreach my $close_time (keys %{$cached->{$epoch}}) {
            my $symbols = $cached->{$epoch}{$close_time};
            $early_closes{$epoch} = $close_time
                if (first { $symbol eq $_ } @$symbols);
        }
    }

    return \%early_closes;
}

__PACKAGE__->meta->make_immutable;
1;
