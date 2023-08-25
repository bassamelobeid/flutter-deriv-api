package BOM::Backoffice::Quant::FeedConfiguration;

use strict;
use warnings;

use Postgres::FeedDB;
use Postgres::FeedDB::Spot;
use Finance::Underlying;
use BOM::MarketData qw(create_underlying);
use base            qw( Exporter );
our @EXPORT_OK = qw( get_existing_drift_switch_spread get_maximum_commission get_maximum_perf save_drift_switch_spread );

our $symbols_with_configurable_spread = [qw/DSI10 DSI20 DSI30/];

use constant LIMIT_DSI10 => 0.00127;
use constant LIMIT_DSI20 => 0.001524;
use constant LIMIT_DSI30 => 0.001334;

=head2 get_existing_drift_switch_spread

Returns a hashref of the current spread configuration for drift switch indices

=cut

sub get_existing_drift_switch_spread {
    my $dbh   = Postgres::FeedDB::read_dbic()->dbh;
    my $query = q{ SELECT * FROM feed.get_latest_underlying_spread_configuration_for_all(?, ?) };

    my $result = $dbh->selectall_hashref($query, 'underlying', undef, $symbols_with_configurable_spread, Date::Utility->new->db_timestamp);

    # we got to return something or else it will not render
    unless ($result) {
        return {'null' => 'null'};
    }

    return $result;
}

=head2 save_drift_switch_spread

Saves the spread configuration for drift switch indices

=cut

sub save_drift_switch_spread {
    my ($symbol, $commission_0, $commission_1, $perf) = @_;

    my $now = Date::Utility->new->db_timestamp;
    my $dbh = Postgres::FeedDB::write_dbic()->dbh;

    my $query = q{ SELECT feed.set_underlying_spread_configuration(?, ?, ?, ?, ?) };

    $dbh->do($query, undef, $now, $symbol, $commission_0, $commission_1, $perf);

}

=head2 current_tick

current tick for a given symbol

=cut

sub current_tick {
    my $symbol = shift;

    return create_underlying($symbol)->spot_tick->{quote};
}

=head2 get_maximum_commission

Returns a hashref of the maximum commission for drift switch indices. Definition is from product quants

=cut

sub get_maximum_commission {

    # hate to hard code these, but currently they don't belong anywhere
    my $limits = {
        'DSI10' => int(current_tick('DSI10') / Finance::Underlying->by_symbol('DSI10')->pip_size * LIMIT_DSI10),
        'DSI20' => int(current_tick('DSI20') / Finance::Underlying->by_symbol('DSI20')->pip_size * LIMIT_DSI20),
        'DSI30' => int(current_tick('DSI30') / Finance::Underlying->by_symbol('DSI30')->pip_size * LIMIT_DSI30)};

    return $limits;
}

=head2 get_maximum_perf

Returns the maximum perf setting for drift switch indices. Definition is from product quants

=cut

sub get_maximum_perf {
    # currently hardcoded based on specs
    return 2;
}

1;
