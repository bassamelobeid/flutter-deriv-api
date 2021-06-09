package BOM::Rules::Result;

=head1 NAME

BOM::Rules::Result

=head1 DESCRIPTION

This object contains a report of performed action.

=cut

use strict;
use warnings;

=head2 new

Create object with initialized properties

=cut

sub new {
    my ($class) = @_;

    return bless {
        has_failure  => 0,
        passed_rules => [],
        failed_rules => {},
        errors       => {}}, $class;
}

=head2 merge

Merge another L<BOM::Rules::Result> values with current instance

=over 4

=item * C<result_instance> - An instance of result you are going to merge to B<$self>

=back

Returns L<BOM::Rules::Result>.

=cut

sub merge {
    my ($self, $result_instance) = @_;

    $self->{has_failure} = 1 if $result_instance->has_failure;
    push $self->{passed_rules}->@*, $result_instance->passed_rules->@*;

    $self->{failed_rules}->%* = ($self->{failed_rules}->%*, $result_instance->failed_rules->%*);
    $self->{errors}->%*       = ($self->{errors}->%*,       $result_instance->errors->%*);

    return $self;
}

=head2 append_failure

Append a failure to the L<BOM::Rules::Result>

=over 4

=item * C<$rule> - the rule name which was failed

=item * C<$error> - the happened error

=back

Returns L<BOM::Rules::Result>.

=cut

sub append_failure {
    my ($self, $rule, $error) = @_;

    $self->{has_failure} = 1;

    $self->{failed_rules}->{$rule} = $error;
    $self->{errors}->{$error->{code}} = 1 if exists $error->{code};

    return $self;
}

=head2 append_success

Append a success to the L<BOM::Rules::Result>

=over 4

=item * C<$rule> - the rule name which was success

=back

Returns L<BOM::Rules::Result>.

=cut

sub append_success {
    my ($self, $rule) = @_;

    push $self->{passed_rules}->@*, $rule;

    return $self;
}

sub has_failure {
    shift->{has_failure};
}

sub passed_rules {
    shift->{passed_rules};
}

sub failed_rules {
    shift->{failed_rules};
}

sub errors {
    shift->{errors};
}

1;
