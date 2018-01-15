package BOM::MyAffiliates::ActivityReporter;

=head1 NAME

BOM::MyAffiliates::ActivityReporter

=head1 DESCRIPTION

This class generates client trading activity reports, including turnover, profit and loss, deposits and withdrawals.

=head1 SYNOPSIS

    use BOM::MyAffiliates::ActivityReporter;

    my $date = '18-Aug-10';

    my $reporter = BOM::MyAffiliates::ActivityReporter->new;
    $reporter->activity_for_date_as_csv($date);

=cut

use Moose;
use Text::CSV;
use Date::Utility;
use File::SortedSeek qw(numeric get_between);
use Format::Util::Numbers qw(formatnumber);

use BOM::Database::DataMapper::MyAffiliates;

=head2 activity_for_date_as_csv

    $reporter->activity_for_date_as_csv('8-Sep-10');

    # currency specific
    $reporter->activity_for_date_as_csv('8-Sep-10', 'USD');

    Produce a nicely formatted CSV output adjusted into passed currency
    (if no currency is passed it defaults to USD)
    for the requested date formatted as follows:

    Date, Client Loginid, company profit/loss from client, deposits, turnover_runbets,
    intraday turnover, other turnover, first funded date, withdrawals

=cut

sub activity_for_date_as_csv {
    my ($self, $date_selection, $currency) = @_;

    return _generate_csv_output($date_selection, $currency);
}

sub _generate_csv_output {
    my ($date_selected, $currency) = @_;

    my $when = Date::Utility->new($date_selected);

    my $myaffiliates_data_mapper = BOM::Database::DataMapper::MyAffiliates->new({
        'broker_code' => 'FOG',
        'operation'   => 'collector',
    });

    $myaffiliates_data_mapper->db->dbic->run(ping => sub { $_->do("SET statement_timeout TO " . 900_000) });

    my $activity;
    if ($currency) {
        $currency = uc $currency;
        $activity = $myaffiliates_data_mapper->get_clients_activity_per_currency({
            date     => $when,
            currency => $currency
        });
    } else {
        $activity = $myaffiliates_data_mapper->get_clients_activity({'date' => $when});
    }

    # default to USD if currency is not defined for rounding
    # as myaffiliates expect everything in USD if specific
    # currency is not passed
    $currency = 'USD' unless $currency;

    my @output;
    # Sometimes we might pull an empty set.
    foreach my $loginid (sort keys %{$activity}) {
        my $csv = Text::CSV->new;

        my $first_funded_date = '';
        if ($activity->{$loginid}->{'first_funded_date'}) {
            $first_funded_date = Date::Utility->new($activity->{$loginid}->{'first_funded_date'})->date_yyyymmdd;
        }
        my @output_fields = (
            $when->date_yyyymmdd,
            $loginid,
            formatnumber('amount', $currency, $activity->{$loginid}->{'pnl'}),
            formatnumber('amount', $currency, $activity->{$loginid}->{'deposits'}),
            formatnumber('amount', $currency, $activity->{$loginid}->{'turnover_runbets'}),
            formatnumber('amount', $currency, $activity->{$loginid}->{'turnover_intradays'}),
            formatnumber('amount', $currency, $activity->{$loginid}->{'turnover_others'}),
            $first_funded_date,
            formatnumber('amount', $currency, $activity->{$loginid}->{'withdrawals'}),
        );
        $csv->combine(@output_fields);
        push @output, $csv->string;
    }

    return @output;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
