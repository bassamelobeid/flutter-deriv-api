package TestHelper;

use strict;
use warnings;
use Test::More;
use Test::Mojo;

use JSON::Schema;
use File::Slurp;
use Data::Dumper;

use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::System::Password;
use BOM::Platform::User;

use base 'Exporter';
use vars qw/@EXPORT_OK/;
@EXPORT_OK = qw/test_schema build_mojo_test build_test_R_50_data create_test_user/;

my ($version) = (__FILE__ =~ m{/(v\d+)/});
die 'unknown version' unless $version;

sub build_mojo_test {
    my $args = shift || {};

    my $headers = {};
    if ($args->{deflate}) {
        $headers = {'Sec-WebSocket-Extensions' => 'permessage-deflate'};
    }
    my $url = "/websockets/$version";
    $url .= '?l=' . $args->{language} if $args->{language};
    my $t = Test::Mojo->new('BOM::WebSocketAPI');
    $t->websocket_ok($url => $headers);

    return $t;
}

sub test_schema {
    my ($type, $data) = @_;

    my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("config/$version/$type/receive.json")));
    my $result    = $validator->validate($data);
    ok $result, "$type response is valid";
    if (not $result) {
        diag Dumper(\$data);
        diag " - $_" foreach $result->errors;
    }
}

sub build_test_R_50_data {
    initialize_realtime_ticks_db();

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD);
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'randomindex',
        {
            symbol => 'R_50',
            date   => Date::Utility->new
        });
}

sub create_test_user {
    my $email     = 'abc@binary.com';
    my $password  = 'jskjd8292922';
    my $hash_pwd  = BOM::System::Password::hashpw($password);
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->set_default_account('USD');
    $client_cr->email($email);
    $client_cr->save;
    my $cr_1 = $client_cr->loginid;
    my $user = BOM::Platform::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->save;
    $user->add_loginid({loginid => $cr_1});
    $user->save;

    return $cr_1;
}

1;
