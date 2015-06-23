#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More (tests => 3);
use Test::Exception;
use Test::NoWarnings;
use BOM::Platform::Runtime;

use BOM::System::Host::Role::Registry;

my $registry;
lives_ok {
    $registry = BOM::System::Host::Role::Registry->new();
}
'Able to instantiate BOM::System::Host::Role::Registry plain';

lives_ok {
    $registry = BOM::System::Host::Role::Registry->new();
}
'Able to instantiate BOM::System::Host::Role::Registry';
