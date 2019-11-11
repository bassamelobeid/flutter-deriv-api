package BOM::Test::Script::ExperianMock;
use strict;
use warnings;

use BOM::Test;

my $pid;

BEGIN {
    if (BOM::Test::on_qa()) {
        $pid = fork();
        die "fork error " unless defined($pid);
        unless ($pid) {
            exec(
                '/home/git/regentmarkets/cpan/local/bin/morbo', '-l',
                'http://localhost:4040',                        '/home/git/regentmarkets/bom-platform/bin/experian_mock.pl'
            );
        }
    }
}

END {
    kill('TERM', $pid) if $pid;
}

1;

