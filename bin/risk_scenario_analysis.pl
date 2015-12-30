#!/usr/bin/perl

package BOM::System::Script::RiskScenarioAnalysis;

=head1 NAME

BOM::System::Script::RiskScenarioAnalysis

=head1 DESCRIPTION

Determine a value for our curent open positions at risk.

=cut
use Moose;
use BOM::System::Config;
use BOM::Platform::Runtime;
use lib qw(/home/git/regentmarkets/bom-backoffice/lib/ /home/git/regentmarkets/bom-market/lib/);
use BOM::RiskReporting::ScenarioAnalysis;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

sub script_run {
    my $self = shift;

    unless (BOM::System::Config::is_master_server()) {
        $self->warning("$0 should only run on master live server");
        return $self->return_value(255);
    }
    $self->info('Starting scenario analysis generation.');
    BOM::RiskReporting::ScenarioAnalysis->new(run_by => $self)->generate;
    $self->info('Completed scenario analysis generation.');

    return 0;
}

sub documentation {
    return qq{
This script creates  risk analysis scenarios for open contracts.
    };
}

sub cli_template {
    return $0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package main;
use strict;

exit BOM::System::Script::RiskScenarioAnalysis->new->run;

