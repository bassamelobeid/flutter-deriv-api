package BOM::Test::WebsocketAPI::SanityChecker::Balance;

no indirect;

use strict;
use warnings;

use parent qw(BOM::Test::WebsocketAPI::SanityChecker::Base);

=head1 NAME

BOM::Test::WebsocketAPI::SanityChecker::Balance - Sanity checks for balance

=head1 SYNOPSIS

    $sanity_checker = BOM::Test::WebsocketAPI::SanityChecker::Balance->new($tester);
    $sanity_checker->published(@responses);

=head1 DESCRIPTION

A collection of sanity checks for balance, its called from within the C<SanityChecker>

=cut

use Test::More;

=head1 METHODS

=head2 published

Run checks on the balance response against the published values

=cut

sub published {
    my ($self, @balance_list) = @_;

    my %balance_by_id = $self->group_by_id(@balance_list)->%*;

    # The first response is published way sooner than received, therefore
    # we will receive too old response errors if run general tests.
    my @first_balances = map { $_->[0] } values %balance_by_id;
    for my $balance (@first_balances) {
        return 0 unless my $expected //= $self->published_response($balance);
        return 0 unless $self->time_travelling_response($balance, $expected);
    }

    my @balances = map { $_->@[1 .. $_->$#*] } values %balance_by_id;
    for my $balance (@balances) {
        return 0 unless $self->general($balance);
    }

    return 1;
}

1;
