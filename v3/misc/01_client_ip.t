use strict;
use warnings;
use Test::More;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test call_mocked_consumer_groups_request/;
use Test::MockModule;
use Clone;

my $valid_client_ip = '98.1.1.1';

my $t = build_wsapi_test({language => 'RU'}, {'x-forwarded-for' => "some text, $valid_client_ip"});
my ($res, $call_params) = call_mocked_consumer_groups_request($t, {logout => 1});
is $call_params->{client_ip}, $valid_client_ip, 'Should send valid ipv4 to RPC getting from header';
is $call_params->{language}, 'RU', 'Should send language';

$t->finish_ok;

done_testing();
