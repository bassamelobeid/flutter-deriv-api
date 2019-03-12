package BOM::Test::WebsocketAPI::SanityChecker::Transaction;

no indirect;

use strict;
use warnings;

use parent qw(BOM::Test::WebsocketAPI::SanityChecker::Base);

=head1 NAME

BOM::Test::WebsocketAPI::SanityChecker::Transaction - Sanity checks for transaction

=head1 SYNOPSIS

    $sanity_checker = BOM::Test::WebsocketAPI::SanityChecker::Transaction->new($tester);
    $sanity_checker->published(@responses);

=head1 DESCRIPTION

A collection of sanity checks for transaction, its called from within the C<SanityChecker>

=cut

use List::Util qw(all);
use Test::More;

=head1 METHODS

=head2 published

Run checks on the balance response against the published balance

=cut

my @valid_actions = qw(buy sell deposit withdraw);

sub published {
    my ($self, @transaction_list) = @_;

    my %tx_by_id = $self->group_by_id(@transaction_list)->%*;

    # skip the first response which contains the subscription id only
    my @transactions = map { $_->@[1 .. $_->$#*] } values %tx_by_id;

    for my $transaction (@transactions) {
        return fail 'Transaction does not have a valid action: ' . (explain $transaction)[0]
            unless grep { $_ eq $transaction->body->{action} } @valid_actions;

        return 0 unless $self->general($transaction);
    }

    return 1;
}

1;
