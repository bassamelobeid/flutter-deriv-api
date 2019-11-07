use strict;
use warnings;
use Test::More;
#use Test::NoWarnings; #
use Test::FailWarnings;
use Encode;
use JSON::MaybeXS;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use utf8;

my $t = build_wsapi_test();

my $req = {ping => '௰'};
my $res = request($req);
is $res->{error}->{code}, 'SanityCheckFailed', 'result error code';
is_deeply $res->{echo_req}, $req, 'Includes the correct echo_req';
# The above character is a special case that API returns msg_type => 'error'
# the following line could be removed if that behaviour changed.
$res->{msg_type} = 'ping' if $res->{msg_type} eq 'error';
test_schema('ping', $res);

# Common unicode characters are fine
$req = {ping => 'äčêfìœúÿ'};
$res = request($req);
is $res->{error}->{code}, 'InputValidationFailed', 'result error code';
is_deeply $res->{echo_req}, $req, 'Includes the correct echo_req';
test_schema('ping', $res);

$req = {
    ping   => '௰',
    req_id => 1
};
$res = request($req);
is $res->{req_id}, $req->{req_id}, 'Includes req_id';

# undefs are fine for some values
request({ping => {key => undef}});

$res = request({
    change_password => 1,
    old_password    => '௰',
    new_password    => '௰'
});
ok $res->{error}->{code} ne 'SanityCheckFailed', 'Do not check value of password key';

$res = request({
    change_password    => 1,
    '௰_old_password' => '௰',
    new_password       => '௰'
});
is $res->{error}->{code}, 'SanityCheckFailed', 'Should be failed if password key consist of non sanity symbols';

$t->finish_ok;

sub request { JSON::MaybeXS->new->decode(Encode::decode_utf8($t->send_ok({json => shift})->message_ok->message->[1])) }

done_testing();
