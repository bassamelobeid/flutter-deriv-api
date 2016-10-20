package TestHelper;

use strict;
use warnings;
use Test::More;
use Test::Mojo;

use JSON::Schema;
use JSON;
use File::Slurp;
use Data::Dumper;
use Date::Utility;

use BOM::WebSocketAPI;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::System::Password;
use BOM::Platform::User;
use Net::EmptyPort qw/empty_port/;

use Test::MockModule;
use Test::MockObject;
use MojoX::JSON::RPC::Client;

use base 'Exporter';
use vars qw/@EXPORT_OK/;
@EXPORT_OK = qw/test_schema build_mojo_test build_test_R_50_data create_test_user call_mocked_client/;

my ($version) = (__FILE__ =~ m{/(v\d+)/});
die 'unknown version' unless $version;

sub build_mojo_test {
    my $args    = shift || {};
    my $headers = shift || {};
    my $callback = shift;

    if ($args->{deflate}) {
        $headers = {'Sec-WebSocket-Extensions' => 'permessage-deflate'};
    }
    my $url = "/websockets/$version";

    my @query_params;
    push @query_params, 'l=' . $args->{language}    if $args->{language};
    push @query_params, 'debug=' . $args->{debug}   if $args->{debug};
    push @query_params, 'app_id=' . $args->{app_id} if $args->{app_id};
    $url .= '?' . join('&', @query_params) if @query_params;

    my $port   = empty_port;
    my $app    = BOM::WebSocketAPI->new;
    my $daemon = Mojo::Server::Daemon->new(
        app    => $app,
        listen => ["http://127.0.0.1:$port"],
    );
    $daemon->start;
    my $t = Test::Mojo->new($app);
    $t->websocket_ok($url => $headers);
    $t->tx->on(json => $callback) if $callback;

    return $t;
}

sub test_schema {
    my ($type, $data) = @_;

    my $validator =
        JSON::Schema->new(JSON::from_json(File::Slurp::read_file("/home/git/regentmarkets/bom-websocket-api/config/$version/$type/receive.json")));
    my $result = $validator->validate($data);
    ok $result, "$type response is valid";
    if (not $result) {
        diag Dumper(\$data);
        diag " - $_" foreach $result->errors;
    }
    return;
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
    return;
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

sub call_mocked_client {
    my ($t, $json) = @_;
    my $call_params;
    my $fake_rpc_client = Test::MockObject->new();
    my $real_rpc_client = MojoX::JSON::RPC::Client->new();
    $fake_rpc_client->mock('call', sub { shift; $call_params = $_[1]->{params}; return $real_rpc_client->call(@_) });

    my $module = Test::MockModule->new('MojoX::JSON::RPC::Client');
    $module->mock('new', sub { return $fake_rpc_client });

    $t = $t->send_ok({json => $json})->message_ok;
    my $res = decode_json($t->message->[1]);

    $module->unmock_all;
    return ($res, $call_params);
}

1;
