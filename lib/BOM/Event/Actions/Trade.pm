package BOM::Event::Actions::Trade;

use strict;
use warnings;
no indirect;

use BOM::Event::Services::Track;

=head1 NAME

BOM::Event::Actions::Transaction

=head1 DESCRIPTION

Provides handlers for trading events, like buy and sell.

=cut

=head2 buy

It is triggered for each B<buy> event emitted.

=cut

sub buy {
    my ($args) = @_;

    return BOM::Event::Services::Track::buy($args);
}

=head2 sell

It is triggered for each B<sell> event emitted.

=cut

sub sell {
    my ($args) = @_;

    return BOM::Event::Services::Track::sell($args);
}

1;
