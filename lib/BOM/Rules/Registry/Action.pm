package BOM::Rules::Registry::Action;

=head1 NAME

BOM::Rules::Registry::Action

=head1 DESCRIPTION

A class that represents B<actions> in rule engine registry. Each action is associated with a collection of applicable B<Rules> known as C<rule_set>.

=cut

use strict;
use warnings;

use Moo;

use BOM::Rules::Registry qw(get_rule);
use BOM::Rules::Result;

=head2 name

The name of the current action.

=cut

has name => (
    is => 'ro',
);

=head2 description

A short description about the action.

=cut

has description => (
    is => 'ro',
);

=head2 category

Action's category; determided by the name of the file in which it is declared.

=cut

has category => (is => 'ro');

=head2 rule_set

An arrayref holding the rules to be applied on action verification.

=cut

has rule_set => (
    is => 'ro',
);

=head2 verify

Verifies the action, applyinng the rules in C<rule_set>.

=cut

sub verify {
    my ($self, $context, $args) = @_;

    my $final_results = BOM::Rules::Result->new();
    for my $rule ($self->rule_set->@*) {
        my $rule_result = $rule->apply($context, $args);

        $final_results->merge($rule_result);
    }

    return $final_results;
}

1;
