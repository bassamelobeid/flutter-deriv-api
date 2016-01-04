use strict;
use warnings;

use Test::More tests => 11;
use Test::Exception;
use Test::NoWarnings;
use BOM::System::Localhost;

my $name = BOM::System::Localhost::name();
like ($name, qr/qa\d+/, 'localhost name');

my $domain = BOM::System::Localhost::domain();
is $domain, 'regentmarkets.com', 'domain';

my $external_domain = BOM::System::Localhost::external_domain();
is $external_domain, 'binary'.$name.'.com', 'external domain';

is BOM::System::Localhost::fqdn(), $name.'.'.$domain, 'fqdn';
is BOM::System::Localhost::external_fqdn(), $name.'.'.$external_domain, 'external fqdn';

is BOM::System::Localhost::is_master_server(), 1, 'master server';
is BOM::System::Localhost::is_feed_server(), 1, 'feed server';

is BOM::System::Localhost::_has_role('binary_role_master_server'), 1, 'master server role';
is BOM::System::Localhost::_has_role('binary_role_feed_server'), 1, 'feed server role';
isnt BOM::System::Localhost::_has_role('random_role'), 1, 'NO random_role';

