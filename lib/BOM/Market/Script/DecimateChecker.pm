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

    my $loop = IO::Async::Loop->new;
    my $app  = BOM::Market::DecimateChecker->new();
    $log->info("$0 is running");
    try {
        $loop->add($app);
        await $app->run;
    } catch ($e) {
        $log->warnf('Failed | %s', $e);
    }

    $loop->remove($app);
    return Future->done;
}

1;
