use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;
use Test::MockModule;
use Clone;

my $t = build_wsapi_test();
$t = $t->send_ok({json => {website_status => 1}})->message_ok;
my $res = decode_json($t->message->[1]);

is $res->{website_status}->{terms_conditions_version},
    BOM::System::Chronicle::get('app_settings', 'binary')->{global}->{cgi}->{terms_conditions_version},
    'terms_conditions_version should be readed from chronicle';

# Update terms_conditions_version at chronicle
my $updated_tcv = 'Version 100 ' . Date::Utility->new->date;
BOM::System::Chronicle::set('app_settings', 'binary', {global => {cgi => {terms_conditions_version => $updated_tcv}}});

is BOM::System::Chronicle::get('app_settings', 'binary')->{global}->{cgi}->{terms_conditions_version}, $updated_tcv, 'Chronickle should be updated';

$t = $t->send_ok({json => {website_status => 1}})->message_ok;
$res = decode_json($t->message->[1]);

is $res->{website_status}->{terms_conditions_version}, $updated_tcv, 'It should return updated terms_conditions_version';

$t->finish_ok;

done_testing();
