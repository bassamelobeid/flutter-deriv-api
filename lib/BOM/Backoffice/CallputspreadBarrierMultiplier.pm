package BOM::Backoffice::CallputspreadBarrierMultiplier;

use strict;
use warnings;
use Date::Utility;
use Text::Trim qw(trim);
use Syntax::Keyword::Try;

use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;
use constant {
    KEY => 'callputspread_barrier_multiplier',
};

=head2 BOM::Backoffice::CallputspreadBarrierMultiplier
    BOM::Backoffice::CallputspreadBarrierMultiplier act as a model that corresponds to all the data-related logic.

    As of now we only need to save and show the config.
=cut

=head2 _dbic_callputspread_barrier_multiplier
    Initiate DB connection
=cut

sub _dbic_callputspread_barrier_multiplier {
    return BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        recorded_date    => Date::Utility->new,
    );
}

=head2 validate_params
    BOM::Backoffice::CallputspreadBarrierMultiplier::validate_params($args)

    This is to validate the params before we save it.
=cut

sub validate_params {
    my $args = shift;

    return {error => "Barrier type is required"}                              if !$args->{barrier_type};
    return {error => "Barrier Multiplier(Forex) input is required"}           if !$args->{forex_callputspread_barrier_multiplier};
    return {error => "Barrier Multiplier(Synthetic Index) input is required"} if !$args->{synthetic_index_callputspread_barrier_multiplier};
    return {error => "Barrier Multiplier(Commodities) input is required"}     if !$args->{commodities_callputspread_barrier_multiplier};

    return $args;
}

=head2 save
    BOM::Backoffice::CallputspreadBarrierMultiplier::save($args)

    'save' will save a new callputspread barrier multiplier config.
=cut

sub save {
    my $args = shift;

    my $id                               = $args->{barrier_type};
    my $callputspread_barrier_multiplier = _dbic_callputspread_barrier_multiplier->get_config(KEY) // {};

    try {
        if (exists $callputspread_barrier_multiplier->{"$id"}) {
            _dbic_callputspread_barrier_multiplier->delete_config(KEY, $id);
        }

        $callputspread_barrier_multiplier->{"$id"} = $args;
        _dbic_callputspread_barrier_multiplier->save_config(KEY, $callputspread_barrier_multiplier);

        return {success => 1};
    } catch ($e) {
        return {error => 'ERR: ' . $e};
    }
}

=head2 show_all
    BOM::Backoffice::CallputspreadBarrierMultiplier::show_all

    'show_all' will return all the exiting callputspread barrier multiplier.
=cut

sub show_all {
    return _dbic_callputspread_barrier_multiplier->get_config(KEY) // {};
}

1;
