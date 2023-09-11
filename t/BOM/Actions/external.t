use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use BOM::Event::Actions::External;

subtest 'nodejs_hello' => sub {
    $log->clear();

    BOM::Event::Actions::External::nodejs_hello();

    $log->contains_ok(qr/Hello from nodejs/);
};

done_testing;
