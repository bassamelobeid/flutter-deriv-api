use warnings;
use strict;

use Test::More;
use Test::Mojo;
use Log::Any::Test;
use Log::Any qw($log);

my $t = Test::Mojo->new('BOM::OAuth');

my $app = $t->app;

my $mojo_log = $app->log;

subtest 'verify_whether_log_any_is_used' => sub {
    $mojo_log->info("This is an info log!");
    my $msgs = $log->msgs();
    is(scalar @{$msgs},        4,                            'size will be 4 (3+1) because there are 3 log lines that the app prints at startup!');
    is($msgs->[3]->{level},    'info',                       'Log level of this log line must be INFO');
    is($msgs->[3]->{category}, 'BOM::OAuth',                 'Log is called from this package');
    is($msgs->[3]->{message},  'info: This is an info log!', 'Check how the log is printed');
};

done_testing();
