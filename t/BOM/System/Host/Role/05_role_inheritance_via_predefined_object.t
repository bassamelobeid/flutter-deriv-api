#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More (tests => 2);
use Test::Exception;
use Test::NoWarnings;

use BOM::System::Host::Role::Registry;
use BOM::Platform::Runtime;

lives_ok {
    BOM::System::Host::Role::Registry->new();
}
'Able to instantiate BOM::System::Host::Role which contains an inherited role specified as an inline object rather than a role name';
