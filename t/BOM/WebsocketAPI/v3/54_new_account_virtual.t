use strict;
use warnings;
use Test::More tests => 5;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_mojo_test();

my $create_vr = {
    new_account_virtual => 1,
    email               => 'test@binary.com',
    client_password     => 'Ac0+-_:@. ',
    residence           => 'de',
};

subtest 'create Virtual account' => sub {
    $t = $t->send_ok({json => $create_vr })->message_ok;
    my $res = decode_json($t->message->[1]);
    ok($res->{account});
    test_schema('new_account_virtual', $res);

    like($res->{account}->{client_id}, qr/^VRTC/, 'got VRTC client');
    is($res->{account}->{currency}, 'USD', 'got currency');
    cmp_ok($res->{account}->{balance}, '==', '10000', 'got balance');
};

subtest 'NO duplicate email' => sub {
    $t = $t->send_ok({json => $create_vr })->message_ok;
    my $res = decode_json($t->message->[1]);

    is($res->{error}->{code}, 'duplicate email', 'duplicate email err code');
    is($res->{account}, undef, 'NO account created');
};

subtest 'insufficient data' => sub {
    delete $create_vr->{residence};

    $t = $t->send_ok({json => $create_vr })->message_ok;
    my $res = decode_json($t->message->[1]);

    is($res->{error}->{code}, 'InputValidationFailed', 'insufficient input');
    is($res->{account}, undef, 'NO account created');
};

$t->finish_ok;
