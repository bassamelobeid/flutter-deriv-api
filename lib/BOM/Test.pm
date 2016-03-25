package BOM::Test;

use strict;
use warnings;

=head1 NAME

BOM::Test - Do things before test

=head1 DESCRIPTION

This module is used to prepare test. It should be used before any other bom modules in the test file.

=over 4

=item $ENV{DB_POSTFIX}

This variable will be set if test is running on qa devbox. If it is set the system will use test database instead of development database.

=cut

BEGIN {
    my $environment = '';
    if (open(my $fh, "<", "/etc/rmg/environment")) {
        $environment = <$fh>;
        close($fh);
    }

    if ($environment =~ /^qa/) {
        ## no critic (RequireLocalizedPunctuationVars)
        $ENV{DB_POSTFIX} = '_test';
    }
}

1;

