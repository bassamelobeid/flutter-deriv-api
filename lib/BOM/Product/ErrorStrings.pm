package BOM::Product::ErrorStrings;

=head1 NAME

BOM::Product::ErrorStrings

=head1 DESCRIPTION

Utilities to deal with preparing messages for logging.

=cut

use 5.010;
use strict;
use warnings;

use base qw( Exporter );
our @EXPORT_OK = qw( format_error_string normalize_error_string );

=head1 FUNCTIONS

=head2 format_error_string

First parameter is a static message.
All others are key value pairs of dynamic content.

Results in: "static message [dynamic: content]"

=cut

sub format_error_string {
    return unless defined $_[0] and @_ % 2;
    return sprintf join(' ', '%s', ('[%s: %s]') x ((@_ - 1) / 2)), map { $_ // 'undef' } @_;
}

=head2 normalize_error_string

Convert a dynamic error string into a more static snake_cased_string

Useful for making tags.

=cut

sub normalize_error_string {
    my $string = shift;

    return unless defined $string;

    $string =~ s/(?<=[^A-Z])([A-Z])/ $1/g;    # camelCase to words
    $string =~ s/\[[^\]]+\]//g;               # Bits between [] should be dynamic

    # Should now be some words.
    return join('_', split /\s+/, lc $string);
}

1;
