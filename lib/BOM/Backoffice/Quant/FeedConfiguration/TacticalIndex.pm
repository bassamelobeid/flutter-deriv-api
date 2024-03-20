package BOM::Backoffice::Quant::FeedConfiguration::TacticalIndex;

use strict;
use warnings;

use BOM::Backoffice::Quant::FeedConfiguration;
use JSON::MaybeUTF8 qw(encode_json_utf8);

use base qw( Exporter );
our @EXPORT_OK = qw( save_tactical_index_params get_existing_params update_tactical_index_spread);

=head2 save_tactical_index_params

Saves the spread configuration for drift switch indices

=cut

sub save_tactical_index_params {
    my ($symbol, $args) = @_;

    my $now = Date::Utility->new->db_timestamp;
    my $dbh = Postgres::FeedDB::write_dbic()->dbh;

    my $query = q{ SELECT feed.set_tactical_index_params(?::TIMESTAMP, ?::JSONB) };

    my $payload_json = encode_json_utf8($args);

    $dbh->do($query, undef, $now, $payload_json);

}

=head2 get_existing_params

Gets the existing index parameters for tactical indices

=cut

sub get_existing_params {
    my $dbh = Postgres::FeedDB::read_dbic()->dbh;

    # hard coding until I figured out how to get this dynamically
    # we got contrarian long and short, momentum long and short
    my $symbols_with_configurable_spread = ['RSIXAGML1', 'RSIXAGML2', 'RSIXAGMS1', 'RSIXAGMS2', 'RSIXAGCL1', 'RSIXAGCL2', 'RSIXAGCS1', 'RSIXAGCS2'];

    my $query = q{ SELECT * FROM feed.get_tactical_index_params(?::TEXT[], ?::TIMESTAMP) };

    my $result = $dbh->selectall_hashref($query, 'underlying', undef, $symbols_with_configurable_spread, Date::Utility->new->db_timestamp);

    # we got to return something or else it will not render
    unless ($result) {
        return {'null' => 'null'};
    }

    # transition state of 0 means "hold"
    # transition state of 1 means "long cash"
    # but in database we using 0 and 1 to represent the information

    for my $symbol (@$symbols_with_configurable_spread) {
        next unless $result->{$symbol};
        $result->{$symbol}->{transition_state} = $result->{$symbol}->{transition_state} ? 'long cash' : 'hold';
    }

    return $result;

}

=head2 update_tactical_index_spread

Updates the spread configuration for tactical indices

=cut

sub update_tactical_index_spread {
    my ($symbol, $alpha, $caliration, $commission) = @_;

    my $now = Date::Utility->new->db_timestamp;
    my $dbh = Postgres::FeedDB::write_dbic()->dbh;

    my $existing_records = get_existing_params();

    # if we don't have the record, we can't update it
    die "No existing record for $symbol. Please save the index parameters first. \n" unless $existing_records->{$symbol};

    my $query = q{ SELECT feed.update_tactical_index_spread(?::TIMESTAMP, ?::JSONB)};

    my $payload = {
        underlying  => $symbol,
        alpha       => $alpha,
        calibration => $caliration,
        commission  => $commission
    };

    $dbh->do($query, undef, $now, encode_json_utf8($payload));
}

1;
