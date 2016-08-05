use strict;
use warnings;
use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/build_mojo_test/;
use Encode;

my $t = build_mojo_test();
$t = $t->send_ok({json => {residence_list => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{msg_type}, 'residence_list';
ok $res->{residence_list};
is_deeply $res->{residence_list}->[0],
    {
    disabled  => 'DISABLED',
    value     => 'af',
    text      => 'Afghanistan',
    phone_idd => '93',
    disabled  => 'DISABLED'
    };

# test RU
$t = build_mojo_test({language => 'RU'});
$t = $t->send_ok({json => {residence_list => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{residence_list};
is_deeply $res->{residence_list}->[0],
    {
    value     => 'au',
    text      => decode_utf8('Австралия'),
    phone_idd => '61'
    };

# back to EN
$t   = build_mojo_test();
$t   = $t->send_ok({json => {residence_list => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{residence_list};
is_deeply $res->{residence_list}->[0],
    {
    disabled  => 'DISABLED',
    value     => 'af',
    text      => 'Afghanistan',
    phone_idd => '93',
    disabled  => 'DISABLED'
    };

$t->finish_ok;

done_testing();
