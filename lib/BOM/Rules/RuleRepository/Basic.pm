package BOM::Rules::RuleRepository::Basic;

=head1 NAME

BOM::Rules::RuleRepositry::Basic

=head1 DESCRIPTION

Contains basic rules, usually needed for the default behavior of conditional rules.

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);

rule 'pass' => {
    description => "A basic rule that always succeeds.",
    code        => sub {
        my $self = shift;

        return 1;
    },
};

1;
