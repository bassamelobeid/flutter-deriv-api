package BOM::Database::DataMapper::HistoricalMarkedToMarket;

=head1 NAME

BOM::Database::DataMapper::HistoricalMarkedToMarket

=head1 DESCRIPTION

This is a class that will collect queries for accounting.historical_marked_to_market

=head1 VERSION

0.1

=cut

use Moose;
use BOM::Database::Model::Constants;

extends 'BOM::Database::DataMapper::Base';

=head1 METHODS

=over


=item eod_market_values_of_month

get market value for each end of day, for period of 1 month
return hashref

=cut

sub eod_market_values_of_month {
    my $self            = shift;
    my $month_first_day = shift;
    my $dbh             = $self->db->dbh;

    my $sql = q{
        SELECT
            FLOOR(
                extract(epoch from calculation_time) / 86400
            ) * 86400 as calculation_time,

            last(market_value ORDER BY calculation_time) as market_value
        FROM
            accounting.historical_marked_to_market
        WHERE
            calculation_time >= ?::date - interval '1 day'
            AND calculation_time < ?::date + interval '1 month'
        GROUP BY
            FLOOR(
                extract(epoch from calculation_time) / 86400
            )
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute($month_first_day, $month_first_day);

    return $sth->fetchall_hashref('calculation_time');
}

no Moose;
__PACKAGE__->meta->make_immutable;

=back

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2010 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
