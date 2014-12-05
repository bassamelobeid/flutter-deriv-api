use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use BOM::Utility::Format::Numbers qw(to_monetary_number_format roundnear);

sub USD_AggregateOutstandingBets_ongivendate {
    my ($date) = @_;

    my $last_second = BOM::Utility::Date->new($date)->epoch + 86399;
    # Pull Agg Outstanding bets from the historical DB.

    my $conn_args = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
            broker_code => 'FOG',
            operation   => 'read_collector',
        })->connection_parameters;
    my $dbh =
        DBI->connect('dbi:Pg:dbname=' . $conn_args->{'database'} . ';host=' . $conn_args->{'host'}, $conn_args->{'user'}, $conn_args->{'password'});

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
