package BOM::Market::Script::DecimateChecker;

use strict;
use warnings;

use BOM::Market::DecimateChecker;
use Syntax::Keyword::Try;
use Future::AsyncAwait;
use Log::Any qw($log);
use IO::Async::Loop;

# Set service name
$0 = 'tick_decimator_checker';    ## no critic

async sub run {
    STDOUT->autoflush(1);

    my $loop  = IO::Async::Loop->new;
    my $app31 = BOM::Market::DecimateChecker->new();
    my $app32 = BOM::Market::DecimateChecker->new(interval => "32m");
    $log->info("$0 is running");
    try {
        $loop->add($app31);
        $loop->add($app32);
        await Future->wait_any($app31->run, $app32->run);
    } catch ($e) {
        $log->warnf('Failed | %s', $e);
    }

    $loop->remove($app31);
    $loop->remove($app32);
    return Future->done;
}

1;
