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

sub init_test {
}

sub get_id_from_uuid_string {
    my $input_string = shift;
    my $first_13     = substr($input_string, 0, 13);
    $first_13 =~ s/-//g;
    return int($first_13);
}

sub get_hashdata_from_uuid_string {
    my $input_string = shift;
    # 16th character is the first character of the hash data
    # nnnnnnnn-nnnn-4nnn-8nnn-nnnnnnnnnnnn
    return substr($input_string, 15, 3) . substr($input_string, 20, 3) . substr($input_string, 24, 12);
}

my $mock_core = Test::MockModule->new('CORE::GLOBAL');
$mock_core->mock('caller', sub { return 'BOM::Service::ValidNamespace' });

subtest 'Check id to uuid' => sub {
    init_test();
    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
        my $uuid = BOM::Service::Helpers::binary_user_id_to_uuid(-1);
        $mock->unmock('caller');
    }
    qr/Could not convert id to UUID.+/, 'negative id throws exception';
    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
        my $uuid = BOM::Service::Helpers::binary_user_id_to_uuid(0);
        $mock->unmock('caller');
    }
    qr/Could not convert id to UUID.+/, 'zero id throws exception';
    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
        my $uuid = BOM::Service::Helpers::binary_user_id_to_uuid(1234567890123);
        $mock->unmock('caller');
    }
    qr/Could not convert id to UUID.+/, '13 digit id throws exception';

    my $uuid;
    $uuid = BOM::Service::Helpers::binary_user_id_to_uuid(1);
    is(get_id_from_uuid_string($uuid),       1,                          'id 1 converted to uuid');
    is(get_hashdata_from_uuid_string($uuid), substr(sha1_hex(1), 0, 18), 'hash data match for id 1');

    $uuid = BOM::Service::Helpers::binary_user_id_to_uuid(123456789012);
    is(get_id_from_uuid_string($uuid),       123456789012,                          'id 123456789012 converted to uuid');
    is(get_hashdata_from_uuid_string($uuid), substr(sha1_hex(123456789012), 0, 18), 'hash data match for id 123456789012');
};

subtest 'Check uuid to id' => sub {
    init_test();

    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
        my $id = BOM::Service::Helpers::uuid_to_binary_user_id('Some random junk');
        $mock->unmock('caller');
    }
    qr/Invalid UUID.+/, 'non uuid throws exception';

    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
        my $id = BOM::Service::Helpers::uuid_to_binary_user_id('');
        $mock->unmock('caller');
    }
    qr/Invalid UUID.+/, 'empty uuid throws exception';

    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
        my $id = BOM::Service::Helpers::uuid_to_binary_user_id('00000000-0000-0000-0000-000000000000');
        $mock->unmock('caller');
    }
    qr/Invalid UUID.+/, 'non uuid-v4 throws exception';

    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
        my $id = BOM::Service::Helpers::uuid_to_binary_user_id('00000000-0000-4000-8000-000000000000');
        $mock->unmock('caller');
    }
    qr/Could not convert UUID.+/, 'zero uuid throws exception';

    # A random uuid v4 has an infinitesimal chance of having a 12 digit id and hash that matches
    # our checksum mechanism so lets just test that one fails.
    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });
        my $id = BOM::Service::Helpers::uuid_to_binary_user_id(UUID::Tiny::create_uuid_as_string(UUID::Tiny::UUID_V4));
        $mock->unmock('caller');
    }
    qr/Could not convert UUID.+/, 'random uuid throws exception';

    my $uuid;
    # As we've verified the to uuid lets use that to check the from uuid
    $uuid = BOM::Service::Helpers::binary_user_id_to_uuid(123456789012);
    is(BOM::Service::Helpers::uuid_to_binary_user_id($uuid), 123456789012, 'id 123456789012 converted to uuid and back to id');

    $uuid = BOM::Service::Helpers::binary_user_id_to_uuid(1);
    is(BOM::Service::Helpers::uuid_to_binary_user_id($uuid), 1, 'id 1 converted to uuid and back to id');

    $uuid = BOM::Service::Helpers::binary_user_id_to_uuid(999999);
    is(BOM::Service::Helpers::uuid_to_binary_user_id($uuid), 999999, 'id 999999 converted to uuid and back to id');
};

$mock_core->unmock('caller');

done_testing();
