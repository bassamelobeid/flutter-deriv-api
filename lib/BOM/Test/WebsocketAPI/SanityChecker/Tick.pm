package BOM::Test::WebsocketAPI::SanityChecker::Tick;

no indirect;

use strict;
use warnings;

use parent qw(BOM::Test::WebsocketAPI::SanityChecker::Base);

=head1 NAME

BOM::Test::WebsocketAPI::SanityChecker::Tick - Sanity checks for tick

=head1 SYNOPSIS

    $sanity_checker = BOM::Test::WebsocketAPI::SanityChecker::Tick->new($tester);
    $sanity_checker->published(@responses);

=head1 DESCRIPTION

A collection of sanity checks for tick, its called from within the C<SanityChecker>

=cut

=head1 METHODS

=head2 published

Run checks on the tick response against the published tick

=cut

sub published {
    my ($self, @tick_list) = @_;

    for my $tick (@tick_list) {
        return 0 unless $self->general($tick);
    }

    return 1;
}

1;
