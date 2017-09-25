package BOM::Backoffice::Script::RiskScenarioAnalysis;

=head1 NAME

BOM::Backoffice::Script::RiskScenarioAnalysis

=head1 DESCRIPTION

Determine a value for our curent open positions at risk.

=cut

use Moose;
use BOM::Platform::Runtime;
use BOM::RiskReporting::ScenarioAnalysis;

sub run {
    my $self = shift;

    BOM::RiskReporting::ScenarioAnalysis->new->generate;

    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
