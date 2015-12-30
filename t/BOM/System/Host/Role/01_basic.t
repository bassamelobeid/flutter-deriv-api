#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More (tests => 7);
use Test::Exception;
use Test::NoWarnings;

use BOM::Platform::Runtime;
use BOM::System::Host::Role::Registry;

use BOM::System::Host::Role;

my $registry = BOM::System::Host::Role::Registry->new();
is('/home/git/regentmarkets/bom-platform/config/roles.yml', $registry->config_file, 'Correct default file');

my $role;

lives_ok {
    $role = BOM::System::Host::Role->new({
        name => 'master_live_server',
    });
}
'Instantiate role';

ok($role->has_role('master_live_server'),  'A role has_role master_live_server');
ok(!$role->has_role('master_thespian'), 'A role does not has_role ficitious roles');

