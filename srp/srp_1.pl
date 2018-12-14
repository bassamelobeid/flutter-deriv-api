use strict;
use warnings;

use BOM::Database::ClientDB;

my $hashref_removal = {
    employment_industry => 'Other',
    income_source       => 'Other',
    occupation          => 'Others',
    source_of_wealth    => 'Other'
};

for my $bc (qw( CR MF MX MLT )) {

    my $clientdb = BOM::Database::ClientDB->new( { broker_code => $bc } )->db->dbic;

    foreach my $key (keys %$hashref_removal) {
        my $val = $hashref_removal->{$key};
        
        $clientdb->txn(
            fixup => sub {
        
            $clientdb->run(
                ping => sub {
                    my $sth = $_->prepare(
                        'UPDATE betonmarkets.financial_assessment SET data = data::jsonb - ? WHERE data->>? = ?'
                    );
                    $sth->execute($key, $key, $val);
                }
            )
        });
    }
} 
