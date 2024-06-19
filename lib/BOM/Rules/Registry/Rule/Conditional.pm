package BOM::Rules::Registry::Rule::Conditional;

=head1 NAME

BOM::Rules::Registry::Rule::Conditional

=head1 DESCRIPTION

A switch-case like conditional rule, with a B<target key> (switch) and a collection of rule sets associated wtih it's specified values (case).

=cut

use strict;
use warnings;

use Moo;

extends 'BOM::Rules::Registry::Rule';

=head2 key

The name of an action arg or context attribute that's being checked by this rule.

=cut

has key => (
    is => 'ro',
);

=head2 rules_per_value

A hashref that maps a specified value to the corresponding ruleset.

=cut

has rules_per_value => (
    is => 'ro',
);

=head2 apply

Applies the rule based on the value that C<key> takes in input arguments consisting:

=over 4

=item C<context> The context of the rule engine.

=item C<action_args> The arguments by which an action is going to take place.

=back

=cut

sub apply {
    my ($self, $context, $action_args) = @_;

    my ($key, $value);

    die 'This rule cannot be applied with empy action args' unless $action_args;
    die 'Invalid context'                                   unless $context && ref $context eq 'BOM::Rules::Context';

    $key = $self->key;
    die "Condition key is missing"                              unless $key;
    die "Condition key '$key' was not found in args or context" unless exists $action_args->{$key} || $context->can($key);

    # try to get the value for args, then from context
    $value = (exists $action_args->{$key}) ? $action_args->{$key} : $context->$key($action_args);

    # fallback to the default rule-set if $value is not found
    my $selected_ruleset = $self->rules_per_value->{$value} // $self->rules_per_value->{'default'} // [];

    $selected_ruleset = [$selected_ruleset] if ref($selected_ruleset) ne 'ARRAY';

    my $final_result = BOM::Rules::Result->new();
    for my $rule (@$selected_ruleset) {
        my $rule_result = $rule->apply($context, $action_args);

        $final_result->merge($rule_result);
    }

    return $final_result;
}

1;
