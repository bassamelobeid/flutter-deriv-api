package BOM::Test::WebsocketAPI::SanityChecker::History;

no indirect;

use strict;
use warnings;

use parent qw(BOM::Test::WebsocketAPI::SanityChecker::Base);

=head1 NAME

BOM::Test::WebsocketAPI::SanityChecker::History - Sanity checks for ticks history

=head1 SYNOPSIS

    $sanity_checker = BOM::Test::WebsocketAPI::SanityChecker::History->new($tester);
    $sanity_checker->published(@responses);

=head1 DESCRIPTION

A collection of sanity checks for history, its called from within the C<SanityChecker>

=cut

use Test::More;
use List::Util qw(first);
use List::MoreUtils qw(first_index);

=head1 METHODS

=head2 published

Run checks on the history response against the published history

=cut

sub published {
    my ($self, @history_list) = @_;

    for my $response (@history_list) {
        my $expected         = first { $_->body->symbol eq $response->body->symbol } $self->expected('history')->@*;
        my $history          = $response->body;
        my $expected_history = $expected->body;

        my @expected_times  = $expected_history->times->@*;
        my @expected_prices = $expected_history->prices->@*;
        my $start           = first_index { $history->times->[0] eq $_ } @expected_times;
        my $end             = first_index { $history->times->[-1] eq $_ } @expected_times;
        my $frame           = {
            times  => [@expected_times[$start .. $end]],
            prices => [@expected_prices[$start .. $end]],
        };
        my $same_size = $self->tester->publisher->published_to_response(
            history => $frame,
            {
                echo_req => {ticks_history => $history->symbol},
            });
        return fail 'Received history: ' . join(', does not match the published: ', explain($response, $same_size))
            unless $same_size->body->matches($history);
    }

    return 1;
}

1;
