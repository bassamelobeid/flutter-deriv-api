package BOM::Test::WebsocketAPI::SanityChecker::WebsiteStatus;

no indirect;

use strict;
use warnings;

use parent qw(BOM::Test::WebsocketAPI::SanityChecker::Base);

=head1 NAME

BOM::Test::WebsocketAPI::SanityChecker::WebsiteStatus - Sanity checks for website_status

=head1 SYNOPSIS

    $sanity_checker = BOM::Test::WebsocketAPI::SanityChecker::WebsiteStatus->new($tester);
    $sanity_checker->published(@responses);

=head1 DESCRIPTION

A collection of sanity checks for website_status, its called from within the C<SanityChecker>

=cut

use Test::More;

=head1 METHODS

=head2 published

Run checks on the website_status responses against the published values

=cut

sub published {
    my ($self, @ws_list) = @_;
    for my $website_status (@ws_list) {
        return 0 unless $self->general($website_status);
    }

    return 1;
}

1;
