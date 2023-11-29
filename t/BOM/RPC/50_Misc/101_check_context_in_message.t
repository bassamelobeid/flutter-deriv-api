use strict;
use warnings;
use Test::More;
use Mojo::IOLoop;
use IO::Async::Loop::Mojo;
use Log::Any::Adapter 'DERIV',
    log_level => 'info',
    stderr    => 'json';
use Log::Any qw($log);
use Path::Tiny;
use BOM::RPC        qw(set_request_logger_context);
use JSON::MaybeUTF8 qw(:v1);
use Test::Deep;
use Test::MockModule;
use BOM::Platform::Token::API;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::RPC;
use BOM::RPC::Registry;
use Struct::Dumb;

my $correlation_id = 'test-correlation-id';
my $context        = {correlation_id => $correlation_id};
my $client         = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

struct
    def               => [qw(name code auth is_async is_readonly caller)],
    named_constructor => 1;
my %params = (
    name        => 'dummy',
    code        => sub { 'success' },
    auth        => undef,
    is_async    => 0,
    is_readonly => 0,
    caller      => 'dummy',
);
my $def = def(%params);
my $file_log_message;
# create a temporary file to store the log message
my $json_log_file = Path::Tiny->tempfile();

subtest 'log message testing with token details' => sub {
    my $token_cr = BOM::Platform::Token::API->new->create_token($client->loginid, 'test');
    my $rpc_sub  = BOM::RPC::wrap_rpc_sub($def);
    my $result   = $rpc_sub->({token => $token_cr}, $context);
    write_log_file($result);
    is($file_log_message->{correlation_id}, 'test-correlation-id', "correlation id in log ok");
    is($file_log_message->{loginid},        $client->loginid,      "login id for authorize call ok");
};

subtest 'log message testing without token details and context' => sub {
    my $rpc_sub = BOM::RPC::wrap_rpc_sub($def);
    my $result  = $rpc_sub->({token => undef}, ());
    write_log_file($result);
    is($file_log_message->{correlation_id}, undef, "correlation id in log ok");
    is($file_log_message->{loginid},        undef, "login id not present for unauthorized call");
};

sub write_log_file () {
    my $result = shift;
    $file_log_message = '';
    $json_log_file->remove;
    my $import_args = {json_log_file => "$json_log_file"};
    Log::Any::Adapter->import('DERIV', $import_args->%*);
    is($result, 'success', 'RPC call with token is successful');
    $log->info("This is an info log");
    $file_log_message = $json_log_file->exists ? $json_log_file->slurp : '';
    chomp($file_log_message);
    $file_log_message = decode_json_text($file_log_message);
    clear_log_context();
}

sub clear_log_context () {
    $log->adapter->clear_context();
}

done_testing();
