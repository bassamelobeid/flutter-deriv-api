use Test::Most;
use Test::MockObject;
use Binary::WebSocketAPI::Hooks;
use Data::Dumper;

use JSON::MaybeUTF8 qw(:v1);

my $schema = Binary::WebSocketAPI::Hooks::_load_schema("tick", "receive");

my $tick =
    "{\"price\":\"9921.253\",\"ask\":\"9921.303\",\"timestamp\":[1697003639,17374],\"bid\":\"9921.204\",\"symbol\":\"BOOM1000\",\"source\":\"crashboom\",\"epoch\":\"1697003639.000\"}";
my $payload = decode_json_utf8($tick);

my $id       = "some-random-string-fsdkfgsdjhf";
my $msg_type = 'tick';
my $result   = {
    id       => "some-random-string-fsdkfgsdjhf",
    symbol   => $payload->{symbol},
    epoch    => 0 + $payload->{epoch},
    quote    => $payload->{price},
    bid      => $payload->{bid},
    ask      => $payload->{ask},
    pip_size => 2,
};

my $resp = {
    msg_type     => $msg_type,
    echo_req     => {ticks => $payload->{symbol}},
    req_id       => 11234234,
    $msg_type    => $result,
    subscription => {id => $id},
};

my $error = Binary::WebSocketAPI::Hooks::_validate_schema_error($schema, $resp);
is $error, undef, 'schema is valid';

delete $resp->{echo_req};
$error = Binary::WebSocketAPI::Hooks::_validate_schema_error($schema, $resp);
ok defined($error), 'schema is not valid';

done_testing();

