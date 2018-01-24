use strict;
use warnings;

use IO::Async::Loop;
use Job::Async::Worker::Redis;

use JSON::MaybeXS;
use Data::Dump 'pp';

my $json = JSON::MaybeXS->new;

my $loop = IO::Async::Loop->new;
$loop->add(
    my $worker = Job::Async::Worker::Redis->new(
        uri => 'redis://127.0.0.1',
        max_concurrent_jobs => 4,
        timeout => 5
    )
);

# Format:
#   name=name of RPC
#   args=JSON-encoded arguments
# Result: JSON-encoded result
$worker->jobs->each(sub {
    my $job = $_;
    my $name = $job->data('name');
    my $data = $json->decode( $job->data('args') );

    # Handle a 'ping' request immediately here
    if($name eq "ping") {
        $_->done($json->encode({
            result => "success",
            (exists $data->{req_id}      ? (req_id      => $data->{req_id}     ) : ()),
            (exists $data->{passthrough} ? (passthrough => $data->{passthrough}) : ()),
        }));
        return;
    }

    print STDERR "TODO: Run RPC <$name> for:\n" . pp($data) . "\n";

    $_->done($json->encode({result => "success"}));
});

$worker->trigger;
$loop->run;
