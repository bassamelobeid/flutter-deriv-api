package BOM::RPC::v3::Annotations;

use Exporter qw(import);
our @EXPORT_OK = qw(annotate_db_calls);

=head1 BOM::RPC::v3::Annotations

This package contains methods for handling DB annotations

=cut

use strict;
use warnings;

=head2 annotate_db_calls

Creates an annotation for an RPC call specifying which databases are read from
and written to.

Accepts a hash with the following optional keys:

=over 2

=item - C<read>: An array reference of databases that are read from.

=item - C<write>: An array reference of databases that are written to.

=back

=over 1

A hashref containing the annotation for the RPC call.

=back

=cut

sub annotate_db_calls {
    my %params = @_;

    $params{'read'}  //= [];
    $params{'write'} //= [];

    my $readonly = @{$params{'write'}} ? 0 : 1;

    return database => {
        read     => $params{read},
        write    => $params{write},
        readonly => $readonly,
    };
}

1;
