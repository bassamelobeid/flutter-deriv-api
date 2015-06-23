#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More (tests => 3);
use Test::Exception;
use Test::NoWarnings;
use Sys::Hostname;

use BOM::Platform::Runtime;

my $hostname = Sys::Hostname::hostname;
if ($hostname =~ /^([^\.]+)\..+/) {
    $hostname = $1;
}
my $me;

$me = BOM::Platform::Runtime->instance->hosts->localhost;

is($me->name,           $hostname, 'name is correct');
is($me->canonical_name, $hostname, 'Canonical name is correct');
