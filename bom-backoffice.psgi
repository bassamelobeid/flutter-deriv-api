#!/usr/bin/env plackup
use strict;
use warnings;

use lib qw!/etc/perl
           /home/git/regentmarkets/bom-app/lib
           /home/git/regentmarkets/bom-web/lib
           /home/git/regentmarkets/bom/lib
           /home/git/regentmarkets/bom-postgres/lib
           /home/git/regentmarkets/bom-backoffice
           /home/git/regentmarkets/bom-backoffice/lib!;

use BOM::System::Plack::App;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

BOM::System::Plack::App::app("root"=>"/home/git/regentmarkets/bom-backoffice");
