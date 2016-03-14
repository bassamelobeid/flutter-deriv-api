#!/usr/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use BOM::TentativeEvents;

use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

print BOM::TentativeEvents::update_event({
    id           => request()->param('id'),
    blankout     => request()->param('blankout'),
    blankout_end => request()->param('blankout_end'),
});

