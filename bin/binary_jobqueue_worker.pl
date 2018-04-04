use strict;
use warnings;

use IO::Async::Loop;
use Job::Async::Worker::Redis;

use JSON::MaybeXS;
use Data::Dump 'pp';

use Getopt::Long;

use BOM::RPC::Registry;
use BOM::RPC; # This will load all the RPC methods into registry as a side-effect

GetOptions(
    'testing|T' => \my $TESTING,
) or exit 1;

if($TESTING) {
    # Running for a unit test; so start it up in test mode
    print STDERR "! Running in unit-test mode !\n";
    require BOM::Test;
    BOM::Test->import;

    require BOM::MT5::User::Async;
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
}

my $json = JSON::MaybeXS->new;

my $loop = IO::Async::Loop->new;
$loop->add(
    my $worker = Job::Async::Worker::Redis->new(
        uri => 'redis://127.0.0.1',
        max_concurrent_jobs => 4,
        timeout => 5
    )
);

my %services = map {
    my $method = $_->name;
    $method => BOM::RPC::wrap_rpc_sub($_)
} BOM::RPC::Registry::get_service_defs();

# Format:
#   name=name of RPC
#   id=string
#   params=JSON-encoded arguments
# Result: JSON-encoded result
$worker->jobs->each(sub {
    my $job = $_;
    my $name = $job->data('name');
    my $params = $json->decode( $job->data('params') );

    # Handle a 'ping' request immediately here
    if($name eq "ping") {
        $_->done($json->encode({
            result => "success",
            (exists $params->{req_id}      ? (req_id      => $params->{req_id}     ) : ()),
            (exists $params->{passthrough} ? (passthrough => $params->{passthrough}) : ()),
        }));
        return;
    }

    print STDERR "Running RPC <$name> for:\n" . pp($params) . "\n";

    if(my $code = $services{$name}) {
        my $result = $code->($params);
        print STDERR "Result:\n" . join( "\n", map { " | $_" } split m/\n/, pp($result) ) . "\n";

        $_->done($json->encode({success => 1, result => $result}));
    }
    else {
        print STDERR "  UNKNOWN\n";
        # Transport mechanism itself succeeded, so ->done is fine here
        $_->done($json->encode({success => 0, error => "Unknown RPC name '$name'"}));
    }
});

$worker->trigger;
$loop->run;
