#!/usr/bin/env plackup
use strict;
use warnings;
use Log::Any::Adapter 'DERIV', stderr => 'json';
use Log::Any qw($log);
use File::Path qw(remove_tree);

use lib qw!/etc/perl
           /home/git/regentmarkets/bom/lib
           /home/git/regentmarkets/bom-postgres/lib
           /home/git/regentmarkets/bom-backoffice
           /home/git/regentmarkets/bom-backoffice/lib!;
use File::Spec;
use BOM::Backoffice::PlackApp;
use Crypt::NamedKeys;

# we use a tmpdir chmodded to 0700 so that the tempfiles are secure
# CGI::Compile will create & use a tmp dir. Create it in advance to avoid permission problem
# Please see https://redmine.deriv.cloud/issues/92102#fix_problems_of_upgrading_pinned_version_modules
my $tmp_dir = File::Spec->catfile(File::Spec->tmpdir, "cgi_compile_$$");

if (-d $tmp_dir) {
    remove_tree($tmp_dir, { safe => 1 }) or die "Could not remove $tmp_dir: $!";
}

        mkdir $tmp_dir          or die "Could not mkdir $tmp_dir: $!";
                chmod 0700, $tmp_dir    or die "Could not chmod 0700 $tmp_dir: $!";
                chown(65534,65534, $tmp_dir);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';
$log->info("Service bom-backoffice is starting...");
BOM::Backoffice::PlackApp::app("root"=>"/home/git/regentmarkets/bom-backoffice");
