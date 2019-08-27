use strict;
use warnings;
use Test::More;
use Encode;
use JSON::MaybeXS;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = build_wsapi_test();

my $res = $t->send_ok({json => {reset_password => 1}})->message_ok;
my $reset_password = JSON::MaybeXS->new->decode(Encode::decode_utf8($res->message->[1]));
is($reset_password->{error}->{code}, 'InputValidationFailed');
test_schema('reset_password', $reset_password);

$res = $t->send_ok({
        json => {
            reset_password      => 1,
            new_password        => 'dummy_password',
            'verification_code' => 'dummy_verification_code'
        }})->message_ok;
$reset_password = JSON::MaybeXS->new->decode(Encode::decode_utf8($res->message->[1]));
is($reset_password->{error}->{code}, 'InvalidToken');
test_schema('reset_password', $reset_password);

$t->finish_ok;

done_testing();
