use strict;
use warnings;
use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;
use UUID::Tiny;
use Data::Dumper;

use BOM::Service;
use BOM::Service::Helpers;
use Digest::SHA qw(sha1_hex);
use UUID::Tiny;

my $mock_core = Test::MockModule->new('CORE::GLOBAL');
$mock_core->mock('caller', sub { return 'BOM::Service::ValidNamespace' });

is BOM::Service::Helpers::_user_identifier_to_binary_user_id(12345678),                                             12345678, 'Numeric passthrough';
is BOM::Service::Helpers::_user_identifier_to_binary_user_id('email@email.com'),                                    undef,    'Email unknowable';
is BOM::Service::Helpers::_user_identifier_to_binary_user_id(BOM::Service::Helpers::binary_user_id_to_uuid(54321)), 54321,    'UUID handling';

$mock_core->unmock('caller');

throws_ok {
    my $mock = Test::MockModule->new('CORE::GLOBAL');
    $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
    BOM::Service::Helpers::_user_identifier_to_binary_user_id('ggfsfewcs');
    $mock->unmock('caller');
}
qr/Unrecognised type of user identifier.+/, 'random string throws exception';

throws_ok {
    my $mock = Test::MockModule->new('CORE::GLOBAL');
    $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
    BOM::Service::Helpers::_user_identifier_to_binary_user_id(-1);
    $mock->unmock('caller');
}
qr/Invalid numeric user identifier.+/, 'negative id throws exception';

throws_ok {
    my $mock = Test::MockModule->new('CORE::GLOBAL');
    $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
    BOM::Service::Helpers::_user_identifier_to_binary_user_id(1234567890123);
    $mock->unmock('caller');
}
qr/Invalid numeric user identifier.+/, 'too large id throws exception';

done_testing();
