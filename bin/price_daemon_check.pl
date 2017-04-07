#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Platform::RedisReplicated;
use DataDog::DogStatsd::Helper;
use JSON::XS qw/encode_json decode_json/;
use Data::Dumper;
use Date::Utility;
use Time::HiRes ();
use Mojo::UserAgent;
use DataDog::DogStatsd::Helper;

my $redis = BOM::Platform::RedisReplicated::redis_pricer;

my @keys = sort @{
    $redis->scan_all(
        MATCH => 'PRICER_STATUS::*',
        COUNT => 20000
    )};

#Getting all PRCER_STATUS keys from redis along with their pricing timing.
my %entries;
for (@keys) {
    my %entry = @{decode_json($redis->get($_))};
    $entries{$entry{ip}} = [] unless exists $entries{$entry{ip}};
    $entry{'diff'} = time - $entry{time};
    $entries{$entry{ip}}[$entry{fork_index}] = \%entry;
}

#print Dumper(\%entries);

#Getting all pricers ips that are currently being used.
my %ip_list;
get_ips("green", \%ip_list);
get_ips("blue",  \%ip_list);
#print Dumper(\%ip_list);

#Comparing
for (keys %ip_list) {
    if (exists $entries{$_}) {
        foreach my $e (@{$entries{$_}}) {
            #first approach is send the time differance to datadog and create a monitor there.
            DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.forks.last_active',
                $e->{'diff'}, {tags => ['tag:' . $e->{'ip'}, 'pid:' . $e->{'pid'}]});
            #second approach is to send PD alerts from this script.
            if ($e->{'diff'} > 10) {
                print
                    "pricer_daemon service in $e->{'ip'} ENV: $ip_list{$_}  with fork PID: $e->{'pid'} did not do any pricing for the last $e->{'diff'} seconds.\n";
                my $error_msg =
                    "TEST PLEASE IGNORE pricer_daemon service in $e->{'ip'} ENV: $ip_list{$_}  with fork PID: $e->{'pid'} did not do any pricing for the last $e->{'diff'} seconds.";
                my $event_type   = "trigger";
                my $incident_key = "pricer:$e->{'ip'}-$e->{'fork_index'}";
                send_pd($error_msg, $event_type, $incident_key);
                #warn "pricer_daemon service in $e->{'ip'} ENV: $ip_list{$_}  with fork PID: $e->{'pid'} did not do any pricing for the last $e->{'diff'} seconds.";
            } else {
                #fork status is ok.
                send_pd("", "resolve", "pricer:$e->{'ip'}-$e->{'fork_index'}");
            }
        }
        delete $entries{$_};
        delete $ip_list{$_};
    } else {
        print "pricer_daemon with an ip: $_ is not doing any pricing while its set to be a pricer in env: $ip_list{$_}\n";
    }
}
for (keys %entries) {
    print "pricer_daemon with an ip: $_ is an orphan\n";
}

sub get_ips {
    my ($env, $ip_list) = shift;

    open FILE, "/tmp/" . $env . "_ip_list" or die $!;
    while (my $line = <FILE>) {

        chomp($line);
        $line =~ s/\r//;
        $ip_list{"$line"} = $env;
    }
    close FILE;
}

sub send_pd {
    my ($error_msg, $type, $incident_key) = @_;
    my $ua            = Mojo::UserAgent->new;
    my $PD_serviceKey = $ENV{'PD_SERVICE_KEY'};
    my $PD_apiKey     = $ENV{'PD_API_KEY'};
    my $PD_enabled    = $ENV{'PD_ENABLED'};
    print "PD_APIKEY = $PD_apiKey, TYPE: $type, $error_msg\n";

    if ($PD_enabled) {
        my $tx = $ua->post(
            'https://events.pagerduty.com/generic/2010-04-15/create_event.json' => {
                "Authorization" => "Token token=$PD_apiKey",
                "Content-type"  => "application/json",
                "Accept"        => "application/vnd.pagerduty+json;version=2"
                } => json => {
                "service_key" => "$PD_serviceKey",
                "event_type"  => "$type",
                "description" => "$error_msg",
                #"incident_key" => "$incident_key"
                });
        if (my $res = $tx->success) { print $res->body }
        else {
            warn $tx->error->{code};
        }
    }
}
