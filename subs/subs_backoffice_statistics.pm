use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use DBI;
use BOM::Utility::Format::Numbers qw(to_monetary_number_format roundnear);

sub USD_AggregateOutstandingBets_ongivendate {
    my ($date) = @_;

    my $last_second = BOM::Utility::Date->new($date)->epoch + 86399;
    # Pull Agg Outstanding bets from the historical DB.

    my $dbh = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
            broker_code => 'FOG',
            operation   => 'collector',
        })->db->dbh;

    my @result = $dbh->selectrow_array(
        qq{ SELECT market_value
        FROM
            accounting.historical_marked_to_market
        WHERE
            calculation_time <= to_timestamp($last_second)
        ORDER BY
            calculation_time DESC
        LIMIT 1
        }
    );

    return roundnear(0.01, $result[0]);
}

1;
