package BOM::Test::WebsocketAPI::SanityChecker::Balance;

no indirect;

use strict;
use warnings;

use BOM::Test::WebsocketAPI::Parameters qw( test_params );

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
    # In case of balance all, we skip based on number of clients
    my @balances = map {
        ;
        my ($first) = values $_->@*;
        my $skip = $first->request->{account} // '' eq 'all' ? scalar test_params()->{client}->@* : 1;
        $_->@[$skip .. $_->$#*]
    } values %balance_by_id;
    for my $balance (@balances) {
        return 0 unless $self->general($balance);
    }

    return 1;
}

1;
