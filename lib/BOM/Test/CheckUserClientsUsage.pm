package BOM::Test::CheckUserClientsUsage;

use strict;
use warnings;

=head2 check_count

`Return the number of usages of the user->clients pattern in the given repo`

=over

=item $repo

The plain text name of the regentmarkets repository

=back

Return value: number of usages

=cut

sub check_count {
    my $repo = shift;
    my $command =
        "find /home/git/regentmarkets/$repo/lib -name '*.pm' -type f -print0 | xargs -0 awk '{ count = gsub(/user->clients[^_]/, \"&\"); for (i = 0; i < count; i++) print FILENAME \":\" NR \": \" \$0 }' | wc -l";
    my $count = `$command`;
    $count =~ s/^\s+|\s+$//g;

    return $count;
}

1;
