#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Platform::RedisReplicated;
use DataDog::DogStatsd::Helper;
#use JSON;
use JSON::XS qw/encode_json decode_json/;
use Data::Dumper;
use Date::Utility;
use Time::HiRes ();

my $redis = BOM::Platform::RedisReplicated::redis_pricer;

my @keys = sort @{ $redis->scan_all(
          MATCH => 'PRICER_STATUS-*',
          COUNT => 20
     ) };

my %v;
for (@keys){
%v = @{decode_json($redis->get($_))};
print "KEY: $_\n";
print Dumper(\%v);
print "DIFF: ". (time - $v{time}) . "\n";
}
