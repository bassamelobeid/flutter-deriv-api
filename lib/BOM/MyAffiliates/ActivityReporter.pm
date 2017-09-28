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
use File::SortedSeek qw(numeric get_between);

use Date::Utility;
use BOM::Database::DataMapper::MyAffiliates;

=head2 activity_for_date_as_csv

    $reporter->activity_for_date_as_csv('8-Sep-10');

    Produce a nicely formatted CSV output adjusted into USD for the requested date formatted as follows:

    Date, Client Login, company profit/loss from client, deposits, intraday turnover, other turnover, first funded date, withdrawals

=cut

sub activity_for_date_as_csv {
    my ($self, $date_selection) = @_;
    my $when = Date::Utility->new({datetime => $date_selection});

    my $myaffiliates_data_mapper = BOM::Database::DataMapper::MyAffiliates->new({
        'broker_code' => 'FOG',
        'operation'   => 'collector',
    });

    $myaffiliates_data_mapper->db->dbic->run(sub { $_->do("SET statement_timeout TO " . 900_000) });

    my $activity = $myaffiliates_data_mapper->get_clients_activity({'date' => $when});

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
            sprintf("%.2f", $activity->{$loginid}->{'pnl'}),
            sprintf("%.2f", $activity->{$loginid}->{'deposits'}),
            sprintf("%.2f", $activity->{$loginid}->{'turnover_runbets'}),
            sprintf("%.2f", $activity->{$loginid}->{'turnover_intradays'}),
            sprintf("%.2f", $activity->{$loginid}->{'turnover_others'}),
            $first_funded_date,
            sprintf("%.2f", $activity->{$loginid}->{'withdrawals'}),
        );
        $csv->combine(@output_fields);
        push @output, $csv->string;
    }

    return @output;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
