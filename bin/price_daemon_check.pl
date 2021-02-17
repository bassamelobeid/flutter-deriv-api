#!/etc/rmg/bin/perl
use strict;
use warnings;

# load this file to force MOJO::JSON to use JSON::MaybeXS
use Mojo::JSON::MaybeXS;
use BOM::Config::Redis;
use DataDog::DogStatsd::Helper;
use Encode;
use JSON::MaybeXS;
use Date::Utility;
use Time::HiRes ();
use Mojo::UserAgent;
use Syntax::Keyword::Try;

my $redis = BOM::Config::Redis::redis_pricer;

#Getting all PRICER_STATUS keys from redis along with their pricing timing.
my %pricers_on_ip;
my %entry;
for (
    $redis->scan_all(
        MATCH => 'PRICER_STATUS::*',
        COUNT => 20000
    ))
{
    my $e = 0;
    try {
        %entry = @{JSON::MaybeXS->new->decode(Encode::decode_utf8($redis->get($_)))};
    } catch {
        $e = 1;
    }
    next if $e;
    $pricers_on_ip{$entry{ip}} = [] unless exists $pricers_on_ip{$entry{ip}};
    $entry{'diff'}             = time - $entry{time};
    $entry{'key'}              = $_;
    #reconsructed hash that has the ip address of the pricer as key and the stats (including calculated time difference) of each fork that it has as an array.
    $pricers_on_ip{$entry{ip}}[$entry{fork_index}] = \%entry;
}

#Getting all pricers ips that are currently registered as valid working pricers.
my $ip_list = get_ips('green');

#find out which pricers that has been terminated and delete their keys from redis. (this will work as garbage collector)
my @ips_not_in_list = grep { not exists $ip_list->{$_} } keys %pricers_on_ip;

for my $ip (@ips_not_in_list) {
    print "pricer_daemon with an ip: $ip is an orphan\n";
    #delete key from redis.
    for (@{$redis->scan_all(MATCH => "PRICER_STATUS::$ip*")}) {
        $redis->del($_);
    }
}

#Comparing and reporting the stats to datadog.
for my $ip (keys %$ip_list) {
    #check if the pricer is registered and doing work
    if (exists $pricers_on_ip{$ip}) {
        #looping through the array of forks.
        foreach my $e (@{$pricers_on_ip{$ip}}) {
            #Check forks last updating time and update datadog if fork is idle for more than 60seconds.
            DataDog::DogStatsd::Helper::stats_inc('pricer_daemon.idle_forks.count',
                {tags => ['tag:' . $e->{'ip'}, 'fork_index:' . $e->{'fork_index'}]})
                if $e->{'diff'} > 60;
        }
    } else {
        #the pricer is registered, but its not doing any work.
        DataDog::DogStatsd::Helper::stats_inc('pricer_daemon.failed.count', {tags => ['tag:' . $ip]});
    }
}

#get the list of registered pricers ips.
#this subrotine is used in production environment.
sub get_ips {
    my $env = shift;
    my $ua  = Mojo::UserAgent->new;
    my $res;
    my $tx = $ua->get("http://172.30.0.60/$env")->success;
    die unless $tx;
    my $b = $tx->body;
    $b =~ s/\r//gm;
    chomp $b;
    return {map { ; $_ => $env } split /\n/, $b};
}
