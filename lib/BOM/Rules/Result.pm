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
        failed_rules => [],
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

    push $self->{failed_rules}->@*, $result_instance->failed_rules->@*;
    $self->{errors}->%* = ($self->{errors}->%*, $result_instance->errors->%*);

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

    $error->{rule} = $rule if ref $error;
    push $self->{failed_rules}->@*, $error;
    $self->{errors}->{$error->{error_code} // $error->{code}} = 1 if ref $error && ($error->{error_code} // $error->{code});

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

=head2 has_failure

Tells if there is a failed rule or all are passed.

=cut

sub has_failure {
    shift->{has_failure};
}

=head2 passed_rules

Returns the list of passed rules.

=cut

sub passed_rules {
    shift->{passed_rules};
}

=head2 failed_rules

Returns the list of failed rules and their failure details.

=cut

sub failed_rules {
    shift->{failed_rules};
}

=head2 errors

Returns the list of all failures occured during verificaiton.

=cut

sub errors {
    shift->{errors};
}

1;
