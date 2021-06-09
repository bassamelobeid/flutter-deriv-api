package BOM::Rules::Registry::Rule;

=head1 NAME

BOM::Rules::Registry::Rule

=head1 DESCRIPTION

Represents a rule in rule-engine's registery.

=cut

use strict;
use warnings;

use Syntax::Keyword::Try;

use BOM::Platform::Context qw(localize);
use BOM::Rules::Result;

use Moo;

=head2 name

Rule's name.

=cut

has name => (
    is => 'ro',
);

=head2 description

A short descrtion of what the rule does.

=cut

has description => (
    is => 'ro',
);

=head2 code

An executalbe code that should be executed on rule application.

=cut

has code => (
    is => 'ro',
);

=head2 apply

Applies the rule by running the object's L<code>. It takes the following arguments:

=over 4

=item C<context> The context of the rule engine.

=item C<action_args> The arguments by which an action is going to take place.

=back

=cut

sub apply {
    my ($self, $context, $action_args) = @_;

    my $result = BOM::Rules::Result->new();

    try {
        $self->code->($self, $context, $action_args);
        $result->append_success($self->name);
    } catch ($e) {
        die $e if $context->stop_on_failure or ref $e ne 'HASH';

        $result->append_failure($self->name, $e);
    }

    return $result;
}

1;
