#!/usr/bin/perl

use 5.010;
use strict;
use warnings;
use Carp;
use BOM::Platform::Runtime;

system("/home/git/regentmarkets/bom-platform/bin/bom_couchdb_maintenance.pm --compact --keep-revisions=50");

