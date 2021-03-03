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

=head2 context_key

The name of a context key that's being checked by this rule.

=cut

has context_key => (
    is => 'ro',
);

=head2 args_key

The name of an action arg that's being checked by this rule.

=cut

has args_key => (
    is => 'ro',
);

=head2 rules_per_value

A hashref that maps a specified value to the corresponding rule-set.

=cut

has rules_per_value => (
    is => 'ro',
);

=head2 apply

Applies the rule based on the value that C<target_key> takes in input arguments consisting:

=over 4

=item C<context> The context of the rule engine.

=item C<action_args> The arguments by which an action is going to take place.

=back

=cut

sub apply {
    my ($self, $context, $action_args) = @_;

    my ($key, $value);
    if ($self->context_key) {
        die 'This rule cannot be applied with empy context' unless $context;

        $key   = $self->context_key;
        $value = $context->$key // '';
    } else {
        die 'This rule cannot be applied with empy action args' unless $action_args;

        $key   = $self->args_key;
        $value = $action_args->{$key} // '';
    }

    # fallback to the default rule-set if $value is not found
    my $selected_rule_set = $self->rules_per_value->{$value} // $self->rules_per_value->{'default'};

    die "The key-value '$key=$value' doesn't match any configured condition" unless $selected_rule_set;

    $selected_rule_set = [$selected_rule_set] if ref($selected_rule_set) ne 'ARRAY';

    $_->apply($context, $action_args) for (@$selected_rule_set);

    return 1;
}

1;
