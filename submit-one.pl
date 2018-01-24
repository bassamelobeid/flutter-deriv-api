#!/usr/bin/env perl
use strict;
use warnings;

use IO::Async::Loop;
use Job::Async;

use JSON::MaybeXS;
use Data::Dump 'pp';

my $json = JSON::MaybeXS->new;

my $loop = IO::Async::Loop->new;
$loop->add(
    my $jobman = Job::Async->new
);

my $client = $jobman->client(
    redis => {
        uri => 'redis://127.0.0.1',
    }
);
$client->start->get;

my $name = shift @ARGV;

my %args;
foreach( @ARGV ) {
    next unless m/^(.+?)=(.*)$/;
    $args{$1} = $2;
}

my $jsonresult = $client->submit(name => $name, args => $json->encode(\%args))->get;
my $result = $json->decode($jsonresult);

print pp($result) . "\n";
