#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use JSON::MaybeUTF8          qw(:v1);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Request qw(request);

use BOM::Backoffice::CallputspreadBarrierMultiplier qw(show_all);

BOM::Backoffice::Sysinit::init();

PrintContentType();
my $r = request();

BrokerPresentation("Callputspread Barrier Multiplier");

my $disabled_write = not BOM::Backoffice::Auth::has_quants_write_access();
BOM::Backoffice::Request::template()->process(
    'backoffice/callputspread_barrier_multiplier/index.html.tt',
    {
        callputspread_barrier_multiplier_controller_url =>
            request()->url_for('backoffice/quant/callputspread_barrier_multiplier/callputspread_barrier_multiplier_controller.cgi'),
        callputspread_barrier_multiplier_configs => _get_callputspread_barrier_multiplier_configs(),
        barrier_types                            => _get_barrier_types()}) || die BOM::Backoffice::Request::template()->error;

# Retrieve all Callputspread Barrier Multiplier config
sub _get_callputspread_barrier_multiplier_configs {
    return BOM::Backoffice::CallputspreadBarrierMultiplier::show_all;
}

# Set Callputspread the barrier type
sub _get_barrier_types {
    my @barrier_type = qw(middle wide);

    return \@barrier_type;
}
