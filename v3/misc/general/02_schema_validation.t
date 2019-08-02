use strict;
use warnings;

use Test::More;
use JSON::MaybeXS;
use Path::Tiny;
use Log::Any::Test;
use Log::Any qw ($log);

use Binary::WebSocketAPI::Hooks;

my $v4_schema_dir = '/home/git/regentmarkets/binary-websocket-api/config/v3';
my $v3_schema_dir = $v4_schema_dir . '/draft-03';

my $caller_info = {
    loginid => 'CR90001',
    app_id  => 12
};
my $json = JSON::MaybeXS->new();

subtest mask_tokens => sub {

    my $schema = {
        '$schema'  => "http://json-schema.org/draft-04/schema#",
        title      => 'Authorize Request',
        properties => {
            "authorize" => {
                type        => "string",
                pattern     => '^[\\w\\-]{1,128}$',
                required    => 1,
                description => 'Blah Blah',
                sensitive   => 1
            }}};

    my $data = {authorize => 'secret'};
    Binary::WebSocketAPI::Hooks::filter_sensitive_fields($schema, $data);
    is($data->{authorize}, '<not shown>', 'result filtered');

    my $schema_array = {
        '$schema'  => "http://json-schema.org/draft-04/schema#",
        title      => 'buy a contract for multiple accounts',
        properties => {
            "tokens" => {
                type        => "array",
                pattern     => '^[\\w\\-]{1,128}$',
                required    => 1,
                description => 'Blah Blah',
                sensitive   => 1
            },
            price => {
                type    => 'number',
                minimum => 0
            }}};
    $data = {
        tokens => ['tokens1', 'token2', 'token3'],
        price  => 12.30
    };
    Binary::WebSocketAPI::Hooks::filter_sensitive_fields($schema_array, $data);
    my $expected = ['<not shown>', '<not shown>', '<not shown>'];
    is_deeply($data->{tokens}, $expected, 'array has been filtered');

    $data = {
        authorize => 'secrect',
        tokens    => ['asdasd1232asd'],
        nested    => {
            token => 'token1',
            name  => 'fred'
        }};
    my $nested_object = {
        type       => 'object',
        properties => {
            token => {
                type      => 'string',
                sensitive => 1
            },
            name => {type => 'string'}}};
    $schema_array->{properties}->{nested} = $nested_object;
    Binary::WebSocketAPI::Hooks::filter_sensitive_fields($schema_array, $data);
    is($data->{nested}->{token}, '<not shown>', 'filtered nested object');

    $data = {
        nested_things => [{
                token => 'token1',
                name  => 'fred',
            },
            {
                token => 'token2',
                name  => 'donald',
            }]};
    my $object_array = {
        'properties' => {
            'nested_things' => {
                'type'  => 'array',
                'items' => {
                    'type'       => 'object',
                    'properties' => {
                        'token' => {
                            'sensitive' => 1,
                            'type'      => 'string'
                        },
                        "name" => {'type' => 'string'}}}}}};
    Binary::WebSocketAPI::Hooks::filter_sensitive_fields($object_array, $data);
    is($data->{nested_things}[0]{token}, '<not shown>', 'filtered object array item 1');
    is($data->{nested_things}[1]{token}, '<not shown>', 'filtered object array item 2');
};

sub encode_schemas {

    my ($action)  = @_;
    my $v4_schema = $json->decode(path("$v4_schema_dir/$action/send.json")->slurp_utf8);
    my $v3_schema = $json->decode(path("$v3_schema_dir/$action/send.json")->slurp_utf8);
    return ($v4_schema, $v3_schema);
}

done_testing();

