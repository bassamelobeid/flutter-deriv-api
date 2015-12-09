#!/usr/bin/perl
package BOM::System::Script::UpdateInterestRates;

use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

use BOM::MarketData::AutoUpdater::InterestRates;
use BOM::Platform::Runtime;

sub documentation { return 'This is a cron that updates interest rates info from Bloomberg to CouchDB.'; }

sub script_run {
    my $self = shift;
    die 'Script only to run on master servers.' unless BOM::Platform::Runtime->instance->hosts->localhost->has_role('master_live_server');
    BOM::MarketData::AutoUpdater::InterestRates->new->run;
    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;
package main;
exit BOM::System::Script::UpdateInterestRates->new->run;
