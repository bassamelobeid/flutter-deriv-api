package Binary::WebSocketAPI::v3::Wrapper::App;

use 5.014;
use strict;
use warnings;
use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);
use JSON::MaybeUTF8 qw(encode_json_utf8);

sub block_app_id {
    my ($c, $rpc_response, $req_storage) = @_;
    return unless $rpc_response == 1;
    my $app_id = $req_storage->{args}{app_delete};
    my $redis  = ws_redis_master();
    my $id     = Time::HiRes::time() . '-' . rand();
    $redis->publish(
        introspection => encode_json_utf8({
                command => 'block',
                args    => [$app_id, 'inactive'],
                id      => $id,
                channel => 'introspection_response',
            }
        ),
        sub {
        });
    return 1;
}

1;
