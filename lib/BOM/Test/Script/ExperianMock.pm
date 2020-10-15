package BOM::Test::Script::ExperianMock;
use strict;
use warnings;

BEGIN {
    local $ENV{NO_PURGE_REDIS} = 1;
    require BOM::Test;
}

my $pid;

BEGIN {
    if (BOM::Test::on_qa()) {
        local $?;
        system("fuser 4040/tcp");
        # $? == 0 means service already running
        if ($?) {
            $pid = fork();
            die "fork error " unless defined($pid);
            unless ($pid) {
                local $ENV{NO_PURGE_REDIS} = 1;
                exec($^X, '-MBOM::Test', '/home/git/regentmarkets/cpan/local/bin/morbo',
                    '-l', 'http://localhost:4040', '/home/git/regentmarkets/bom-platform/bin/experian_mock.pl');
            }
        }
    }
}

END {
    kill('TERM', $pid) if $pid;
}

1;

