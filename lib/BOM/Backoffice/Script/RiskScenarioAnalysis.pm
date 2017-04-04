package BOM::Backoffice::Script::RiskScenarioAnalysis;

=head1 NAME

BOM::Backoffice::Script::RiskScenarioAnalysis

=head1 DESCRIPTION

Determine a value for our curent open positions at risk.

=cut

use Moose;
use BOM::Platform::Runtime;
use lib qw(/home/git/regentmarkets/bom-backoffice/lib/ /home/git/regentmarkets/bom-market/lib/);
use BOM::RiskReporting::ScenarioAnalysis;
with 'App::Base::Script';

sub script_run {
    my $self = shift;

    BOM::RiskReporting::ScenarioAnalysis->new->generate;

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
