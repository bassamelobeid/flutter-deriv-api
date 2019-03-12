package BOM::Test::WebsocketAPI::SanityChecker;

no indirect;

use strict;
use warnings;

=head1 NAME

BOM::Test::WebsocketAPI::SanityChecker - A collection of sanity checks for each response

=head1 SYNOPSIS

    $sanity_checker = BOM::Test::WebsocketAPI::SanityChecker->new($tester);
    $sanity_checker->check($ticks);

=head1 DESCRIPTION

Sanity checks based on the type of the received response. Constructor receives
a hash ref to published values in the C<BOM::Test::WebsocketAPI>.

=cut

use Scalar::Util qw(weaken);
use Test::More;
use List::Util qw(reduce);
use Module::Load ();
use Module::Pluggable search_path => ['BOM::Test::WebsocketAPI::SanityChecker'];
Module::Load::load($_) for sort __PACKAGE__->plugins;

sub new {
    my ($class, $tester) = @_;

    my $self = {};
    weaken($self->{tester} = $tester);

    return bless $self, $class;
}

=head1 ACCESSORS

=head2 tester

A tester instance that runs this sanity check

=cut

sub tester { return shift->{tester} }

=head2 responses

A list of responses to run the checks on

=cut

sub responses { return shift->{responses} // [] }

sub checks_list {
    return [qw(
            check_duplicates
            check_skipped
            published
            schema_v4
            schema_v3
            )];
}

=head1 METHODS

=head2 check

Runs sanity checks on the given list of response lists.
Each element of the given list is a list of responses received from different
contexts (possibly running in parallel) in a suite.

=cut

sub check {
    my ($self, $responses_list) = @_;

    my $result = 1;
    for my $responses ($responses_list->@*) {
        my @sorted_resps = sort { $a->arrival_time <=> $b->arrival_time } $responses->@*;
        my %grouped = $self->group_by_type(@sorted_resps)->%*;
        for my $type (keys %grouped) {
            my $class_name = __PACKAGE__ . '::' . $type =~ s/(_?)([^_]+)/ucfirst($2)/egr;
            next unless $class_name->isa(__PACKAGE__);
            my $checker = $self->{$type} //= $class_name->new($self->tester, @sorted_resps,);
            my @responses_per_type = grep { !$_->is_error } $grouped{$type}->@*;
            for my $check ($self->checks_list->@*) {
                my $skip_sanity_checks = $self->tester->skip_sanity_checks;
                unless (ref($skip_sanity_checks) eq 'HASH'
                    and exists $skip_sanity_checks->{$type}
                    and grep { $_ eq $check } $skip_sanity_checks->{$type}->@*)
                {
                    $result &&= $checker->$check(@responses_per_type);
                }
            }
        }
    }
    return $result;
}

=head1 METHODS

=head2 group_by_id

Given an array ref of responses, returns a hashref of subscription responses
per subscription id.

=cut

sub group_by_id {
    my ($self, @responses) = @_;

    my %subscriptions;

    for my $response (@responses) {
        next unless $response->subscription;
        push $subscriptions{$response->subscription->id}->@*, $response;
    }

    return \%subscriptions;
}

=head2 group_by_type

Groups responses by type

=cut

sub group_by_type {
    my ($self, @responses) = @_;

    my %grouped;

    for my $response (@responses) {
        push $grouped{$response->type}->@*, $response;
    }

    return \%grouped;
}

=head2 expected

=cut

sub expected {
    my ($self, $type) = @_;

    return $self->tester->publisher->published->{$type} // [];
}

1;
