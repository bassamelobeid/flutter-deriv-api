use warnings;
use strict;

use Test::More;
use Test::Mojo;
use Log::Any::Test;
use Log::Any qw($log);

my $t = Test::Mojo->new('BOM::OAuth');

my $app     = $t->app;
my $app_log = $app->log;

subtest 'verify_whether_log_any_is_used' => sub {
    $app_log->info("This is an info log!");
    my $msgs = $log->msgs();
    #TODO after this card moved to ready remove this SKIP
    SKIP: {
        skip "skipping this test since app_log from chef returns Mojo::Log instance until this new chef PR merged", 1
            if (ref $app_log eq 'Mojo::Log');
        is(scalar @{$msgs}, 4, 'size will be 4 (3+1) because there are 3 log lines that the app prints at startup!');
    }

    is($msgs->[0]->{level},    'warning',                         'Log level of this log line must be WARN as in BOM::OAuth ');
    is($msgs->[0]->{category}, 'BOM::OAuth',                      'Log is called from BOM::OAuth package');
    is($msgs->[0]->{message},  'BOM-OAuth:            Starting.', 'Check how the log is printed');
};

done_testing();
