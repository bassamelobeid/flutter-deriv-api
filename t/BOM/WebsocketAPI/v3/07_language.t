use strict;
use warnings;
use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/build_mojo_test/;
use Encode;

## test without deflate
my $t = build_mojo_test({language => 'RU'});

$t = $t->send_ok({json => {residence_list => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
ok $res->{residence_list};
is_deeply $res->{residence_list}->[0],
    {
    value => 'au',
    text  => decode_utf8('Австралия')};

$t->finish_ok;

done_testing();
