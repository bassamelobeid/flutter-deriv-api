#!/usr/bin/env plackup
use strict;
use warnings;

use lib qw!/etc/perl
           /home/git/regentmarkets/bom-app/lib
           /home/git/bom/lib
           /home/git/bom/database/lib
           /home/git/regentmarkets/bom-backoffice
           /home/git/regentmarkets/bom-backoffice/lib!;

use BOM::System::Plack::App;

BOM::System::Plack::App::app("root"=>"/home/git/regentmarkets/bom-backoffice");
