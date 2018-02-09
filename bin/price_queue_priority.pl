#!/etc/rmg/bin/perl
use strict;
use warnings;
# load this file to force MOJO::JSON to use JSON::MaybeXS
use Mojo::JSON::MaybeXS;
use Getopt::Long;
use Mojo::IOLoop;
use Mojo::Redis2;
use Path::Tiny;
use YAML qw/LoadFile/;
use Log::Any qw($log);
use Log::Any::Adapter ('Stdout');

GetOptions("pid-file=s" => \my $pid_file);
if ($pid_file) {
    $pid_file = Path::Tiny->new($pid_file);
    $pid_file->spew($$);
}

my $cf = LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write};
my $redis_url = Mojo::URL->new("redis://$cf->{host}:$cf->{port}");

$redis_url->userinfo('dummy:' . $cf->{password}) if $cf->{password};
my $redis = Mojo::Redis2->new(url => $redis_url);
$redis->on(
    message => sub {
        my ($redis, $v, $key) = @_;
        $log->info('pricer_jobs_priority updating...');
        $redis->lpush('pricer_jobs_priority', $v);
        $log->info('pricer_jobs_priority updated.');
    });
$redis->subscribe(
    ['high_priority_prices'],
    sub {
        my ($self, $err) = @_;
        warn "Had error when subscribing - $err" if $err;
    });
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

