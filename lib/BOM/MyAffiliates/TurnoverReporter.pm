package BOM::MyAffiliates::TurnoverReporter;

=head1 NAME

BOM::MyAffiliates::TurnoverReporter

=head1 DESCRIPTION

This class generates turnover report for clients.

It includes contract buy price, payout price, probability
and contract reference id

=head1 SYNOPSIS

    use BOM::MyAffiliates::TurnoverReporter;

    my $date = '18-Aug-10';

    my $reporter = BOM::MyAffiliates::TurnoverReporter->new;
    $reporter->activity_for_date_as_csv($date);

=cut

use Date::Utility;
use File::SortedSeek qw/numeric get_between/;
use Format::Util::Numbers qw/financialrounding/;
use Moose;
use Text::CSV;

use BOM::Database::DataMapper::MyAffiliates;

=head2 activity_for_date_as_csv

    $reporter->activity_for_date_as_csv('8-Sep-10');

    Produce a nicely formatted CSV output adjusted into USD
    for the requested date formatted as follows:

    Transaction date, Client loginid, Buy price (stake), payout price,
    probablity (stake/payout_price*100), contract reference id

=cut

sub activity_for_date_as_csv {
    my ($self, $date_selection) = @_;
    my $when = Date::Utility->new({datetime => $date_selection});

    my $myaffiliates_data_mapper = BOM::Database::DataMapper::MyAffiliates->new({
        'broker_code' => 'FOG',
        'operation'   => 'collector',
    });

    $myaffiliates_data_mapper->db->dbh->do("SET statement_timeout TO " . 900_000);

    my $activity = $myaffiliates_data_mapper->get_trading_activity({'date' => $when});

    my (@output, @output_fields, $csv);
    foreach my $obj (@$activity) {
        $csv           = Text::CSV->new;
        @output_fields = (
            # transaction date
            Date::Utility->new($obj->[0])->date_yyyymmdd,
            # loginid
            $obj->[1],
            # stake
            financialrounding('price', 'USD', $obj->[2]),
            # payout
            financialrounding('price', 'USD', $obj->[3]),
            # probability
            $obj->[4],
            # contract reference id
            $obj->[5]);
        $csv->combine(@output_fields);
        push @output, $csv->string;
    }

    return @output;
}

=head2 get_headers_for_csv

    BOM::MyAffiliates::TurnoverReporter::get_headers_for_csv

    Headers for turnover csv

=cut

sub get_headers_for_csv {
    my $csv = Text::CSV->new;
    $csv->combine(qw/Date Loginid Stake PayoutPrice Probability ReferenceId/);
    return $csv->string;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
