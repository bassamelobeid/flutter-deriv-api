package BOM::Test::Script::OnfidoMock;
use strict;
use warnings;

BEGIN {
    local $ENV{NO_PURGE_REDIS} = 1;
    require BOM::Test;
}

my $pid;

BEGIN {
    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $ENV{ONFIDO_URL} = 'http://localhost:3000';
    $pid = fork();
    die "fork error " unless defined($pid);
    unless ($pid) {
        local $ENV{NO_PURGE_REDIS} = 1;

        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec($^X, '/home/git/regentmarkets/cpan/local/bin/mock_onfido.pl');
    }

    sleep 3;    # waiting for server start
}

END {
    kill('TERM', $pid) if $pid;
}

1;
