use strict;
use warnings;
use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;
use Encode;

my $t = build_wsapi_test();
$t = $t->send_ok({json => {residence_list => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{msg_type}, 'residence_list';
ok $res->{residence_list};
is_deeply $res->{residence_list}->[0],
    {
    disabled  => 'DISABLED',
    value     => 'ir',
    text      => 'Iran, Islamic Republic of',
    phone_idd => '98',
    disabled  => 'DISABLED'
    };

# test RU
$t = build_wsapi_test({language => 'RU'});
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
$t   = build_wsapi_test();
$t   = $t->send_ok({json => {residence_list => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{residence_list};
is_deeply $res->{residence_list}->[0],
    {
    disabled  => 'DISABLED',
    value     => 'ir',
    text      => 'Iran, Islamic Republic of',
    phone_idd => '98',
    disabled  => 'DISABLED'
    };

$t->finish_ok;

done_testing();
