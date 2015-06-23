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
is('/home/git/bom/config/files/roles.yml', $registry->config_file, 'Correct default file');

my $role;
my $other_role;

lives_ok {
    $other_role = BOM::System::Host::Role->new({
        name => 'postgres_server',
    });
}
'Instantiate other server';

lives_ok {
    $role = BOM::System::Host::Role->new({
        name     => 'streaming_server',
        inherits => [$other_role],
    });
}
'Able to instantiate a BOM::System::Host::Role manually';

ok($role->has_role('streaming_server'), 'A role has_role itself');
ok($role->has_role('postgres_server'),  'A role has_role its inherited roles');
ok(!$role->has_role('master_thespian'), 'A role does not has_role ficitious roles');

# Cause some deliberate duplication for unit testing purposes
$role->inherits([@{$role->inherits}, @{$role->inherits}]);
