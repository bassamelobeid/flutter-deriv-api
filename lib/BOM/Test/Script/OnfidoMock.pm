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
    $ENV{ONFIDO_URL} = 'http://localhost:4039';
    $pid = fork();
    die "fork error " unless defined($pid);
    unless ($pid) {
        local $ENV{NO_PURGE_REDIS} = 1;
        exec($^X, '-MBOM::Test', '/home/git/regentmarkets/cpan/local/bin/morbo',
            '-l', $ENV{ONFIDO_URL}, '-m', 'production', '/home/git/regentmarkets/cpan/local/bin/mock_onfido.pl');
    }

    sleep 1;    # waiting for server start
}

END {
    kill('TERM', $pid) if $pid;
}

1;
