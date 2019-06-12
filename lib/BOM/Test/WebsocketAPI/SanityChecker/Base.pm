package BOM::Test::WebsocketAPI::SanityChecker::Base;

no indirect;

use strict;
use warnings;

use parent qw(BOM::Test::WebsocketAPI::SanityChecker);

=head1 NAME

BOM::Test::WebsocketAPI::SanityChecker::Base - Base class for specialized sanity checkers

=head1 SYNOPSIS

    $sanity_checker = BOM::Test::WebsocketAPI::SanityChecker::Base->new($tester, @all_responses);
    $sanity_checker->published(@responses_to_check);

=head1 DESCRIPTION

A base class for sanity checkers.

=cut

use List::Util qw(first reduce);
use List::MoreUtils qw(first_index);
use Scalar::Util qw(weaken);
use Test::More;
use JSON::MaybeXS;
use Path::Tiny;
use JSON::Schema;
use JSON::Validator;

my $json = JSON::MaybeXS->new;

sub new {
    my ($class, $tester, @responses) = @_;

    my $self = {responses => \@responses};
    weaken($self->{tester} = $tester);

    return bless $self, $class;
}

=head1 ACCESSORS

=head2 tester

A tester instance that runs this sanity check

=cut

sub tester { return shift->{tester} }

sub schemas {
    return shift->{schemas} //= do {
        my $schemas;
        my $iter = path("//home/git/regentmarkets/binary-websocket-api/config/v3")->iterator({recurse => 1});
        while (my $path = $iter->()) {
            next unless $path->basename eq 'receive.json';
            my $version = ($path->parent(2)->basename eq 'draft-03') ? 'v3' : 'v4';
            my $method = $path->parent->basename;
            $schemas->{$version}->{$method} = $json->decode($path->slurp_utf8);
        }
        $schemas;
        }
}

=head1 METHODS

=head2 published

Runs checks against the published values over a list of the received responses

=cut

sub published {
    note 'Sanity checker ' . __PACKAGE__ . ' is not implemented.';

    return 1;
}

=head2 check_skipped

Check if any response in the subscription is skipped.

=cut

sub check_skipped {
    #my ($self, @subscriptions) = @_;

    # TODO: Add a test for skipped responses, this requires existance of a map
    # between the expected responses and the received ones.

    return 1;
}

=head2 check_duplicates

Check if there is any duplicated responses.

=cut

sub check_duplicates {
    my ($self, @subscriptions) = @_;
    my @seen_subscriptions;
    for my $subscription (@subscriptions) {
        next unless $subscription->subscription;
        my $duplicate = first { $subscription->body->matches($_->body) } @seen_subscriptions;
        return fail 'Duplicate response: ' . join ', matches: ', explain $subscription, $duplicate
            if $duplicate and $subscription->arrival_time - $duplicate->arrival_time > $self->tester->max_response_delay;
        push @seen_subscriptions, $subscription;
    }

    return 1;
}

=head2 general

General sanity checks common between all responses

=cut

sub general {
    my ($self, $response) = @_;

    return 0 unless my $expected = $self->published_response($response);
    unless ($self->is_sanity_ckeck_skipped($response->type, 'time_travelling_response')) {
        return 0 unless $self->time_travelling_response($response, $expected);
    }
    unless ($self->is_sanity_ckeck_skipped($response->type, 'too_old_response')) {
        return 0 unless $self->too_old_response($response, $expected);
    }

    return 1;
}

=head2 published_response

Finds and returns a given response in the published values, fails otherwise

=cut

sub published_response {
    my ($self, $response) = @_;
    return fail 'Response was not published: ' . (explain $response)[0]
        unless my $expected = first { $_->body->matches($response->body) } $self->expected($response->type)->@*;
    return $expected;

}

=head2 time_travelling_response

Fails if the expected response is newer than the received response

=cut

sub time_travelling_response {
    my ($self, $response, $expected) = @_;
    return fail 'Response was received before being published! expected: ' . join ", received: ", explain $expected, $response
        # Assuming max_response_delay is small, because there's a race condition
        # don't want to see this error to often, otherwise, max_response_delay
        # wasn't needed to be subtracted.
        if $response->arrival_time < $expected->arrival_time - $self->tester->max_response_delay;
    return 1;
}

=head2 too_old_response

Fails if the expected response is way older than the received response, the maximum acceptable
delay is set by C<max_response_delay> passed to the tester constructor.

=cut

sub too_old_response {
    my ($self, $response, $expected) = @_;
    my $delay = sprintf '%.3f', $response->arrival_time - $expected->arrival_time;

    return fail "There was a large delay (${delay}s). expected: " . join ", received: ", explain $expected, $response
        if $delay > $self->tester->max_response_delay;

    return 1;
}

=head2 schema_v3

Fails if the expected response does not validate against our JSON draft-03 receive schema

=cut

sub schema_v3 {
    my ($self, @subscriptions) = @_;
    for my $response (@subscriptions) {
        next unless (my $schema = $self->schemas->{v3}->{$response->type});
        my $result = JSON::Schema->new($schema, format => \%JSON::Schema::FORMATS)->validate($response->raw);

        # $result is true for no errors
        return fail "JSON v3 schema validation error: " . join ", received: ", explain $result->errors, $response->raw
            unless $result;
    }
    return 1;
}

=head2 schema_v4

Fails if the expected response does not validate against our JSON draft-04 receive schema

=cut

sub schema_v4 {
    my ($self, @subscriptions) = @_;
    for my $response (@subscriptions) {
        next unless (my $schema = $self->schemas->{v4}->{$response->type});
        my @errors = JSON::Validator->new()->schema($schema)->validate($response->raw);
        return fail "JSON v4 schema validation error: " . join ", received: ", explain @errors, $response->raw
            if @errors;
    }
    return 1;
}

1;
