#!/usr/bin/perl

use Data::Dumper;
use BOM::Platform::Client;
use BOM::Platform::Client::Login;

my $l = shift;
my $p = shift || die <<USAGE;
usage: login.pl LOGINID PWD [1]
USAGE

print Dumper(
    BOM::Platform::Client->new({loginid=>$l})->login(
        password    => $p,
        ip          => '192.168.1.1',
        environment => 'login.pl script'
    )
);

