package BOM::Backoffice::Script::RiskScenarioAnalysis;

=head1 NAME

BOM::Backoffice::Script::RiskScenarioAnalysis

=head1 DESCRIPTION

Determine a value for our curent open positions at risk.

=head1 SYNOPSIS

To get the risk report for today open positions: perl bin/risk_scenario_analysis.pl 

To get risk report for open positions at 00GMT of a historical date: perl bin/risk_scenario_analysis.pl '2018-01-16'

=cut

use Moose;
use BOM::Platform::Runtime;
use Date::Utility;
use BOM::RiskReporting::ScenarioAnalysis;

sub run {
    my $self = shift;
    my $date = shift(@ARGV);
    BOM::RiskReporting::ScenarioAnalysis->new->generate($date);

    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
