use Test::Most;
use Test::MockObject;
use Binary::WebSocketAPI::FastSchemaValidator;
use Data::Dumper;

use JSON::MaybeUTF8 qw(:v1);

use JSON::MaybeXS;

sub prepare {
    my ($schema_str, $options) = @_;
    my $schema_obj = eval { decode_json_utf8($schema_str) };
    if ($@) {
        return "Error parsing JSON: <<$schema_str>>:" . $@;
    }
    return Binary::WebSocketAPI::FastSchemaValidator::prepare_fast_validate($schema_obj, $options);
}

sub prepare_get_error {
    my ($fast_schema, $error_str) = prepare(@_);
    return $error_str;
}

sub check {
    my ($schema, $message) = @_;
    my $message_obj = decode_json_utf8($message);
    my $error       = Binary::WebSocketAPI::FastSchemaValidator::fast_validate_and_coerce($schema, $message_obj);
    return $error if defined($error);
    my $json = JSON::MaybeXS->new(canonical => 1);
    return $json->encode($message_obj);
}

subtest 'Object with String' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"string"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"b"}'),   '{"a":"b"}';
    is check($fast_schema, '{"a":1}'),     '{"a":"1"}';
    is check($fast_schema, '{"a":"1"}'),   '{"a":"1"}';
    is check($fast_schema, '{"a":1.1}'),   '{"a":"1.1"}';
    is check($fast_schema, '{"a":"1.1"}'), '{"a":"1.1"}';
    like check($fast_schema, '{"a":null}'),            qr/Expected string, found: null/;
    like check($fast_schema, '{"a":[1,2]}'),           qr/Expected string, found: Array/;
    like check($fast_schema, '{"a":{"is":"string"}}'), qr/Expected string, found: Object/;
};

subtest 'Object with String with max length' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"string","maxLength":3}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"b"}'),   '{"a":"b"}';
    is check($fast_schema, '{"a":"bb"}'),  '{"a":"bb"}';
    is check($fast_schema, '{"a":"bbb"}'), '{"a":"bbb"}';
    like check($fast_schema, '{"a":"bbbb"}'), qr/Value too long, greater than maximum \(3\): bbbb/;
};

subtest 'Object with Enum' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"string","enum":["a","b"]}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"b"}'), '{"a":"b"}';
    like check($fast_schema, '{"a":1}'),     qr/Expected string in enum list, found: 1/;
    like check($fast_schema, '{"a":"1"}'),   qr/Expected string in enum list, found: 1/;
    like check($fast_schema, '{"a":1.1}'),   qr/Expected string in enum list, found: 1.1/;
    like check($fast_schema, '{"a":"1.1"}'), qr/Expected string in enum list, found: 1.1/;
    like check($fast_schema, '{"a":null}'),  qr/Expected enum_string, found: null/;
};

subtest 'Object with Number Enum' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"number","enum":["1.0",1.2]}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"1.0"}'), '{"a":1.0}';
    is check($fast_schema, '{"a":1.0}'),   '{"a":1}', "1.0 turns into 1, that is OK as they should be the same";
    is check($fast_schema, '{"a":"1.2"}'), '{"a":1.2}';
    is check($fast_schema, '{"a":1.2}'),   '{"a":1.2}';
    like check($fast_schema, '{"a":"b"}'),   qr/Expected number in enum list, found: b/;
    like check($fast_schema, '{"a":"1.1"}'), qr/Expected number in enum list, found: 1\.1/;
    like check($fast_schema, '{"a":1.1}'),   qr/Expected number in enum list, found: 1\.1/;
    like check($fast_schema, '{"a":null}'),  qr/Expected enum_number, found: null/;
};

subtest 'Object with Integer Enum' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"integer","enum":["10",12]}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"10"}'), '{"a":10}';
    is check($fast_schema, '{"a":10}'),   '{"a":10}';
    is check($fast_schema, '{"a":"12"}'), '{"a":12}';
    is check($fast_schema, '{"a":12}'),   '{"a":12}';
    like check($fast_schema, '{"a":"b"}'),  qr/Expected integer in enum list, found: b/;
    like check($fast_schema, '{"a":"11"}'), qr/Expected integer in enum list, found: 11/;
    like check($fast_schema, '{"a":11}'),   qr/Expected integer in enum list, found: 11/;
    is check($fast_schema, '{"a":10.0}'), '{"a":10}', "Should this be allowed? It is basically the same, so we allow it";
    like check($fast_schema, '{"a":"10.0"}'), qr/Expected integer in enum list, found: 10.0/;
    like check($fast_schema, '{"a":null}'),   qr/Expected enum_integer, found: null/;
};

subtest 'Invalid schema with non Number in  Number Enum' => sub {
    like prepare_get_error('{"type":"object","properties":{"a":{"type":"number","enum":["b"]}}}'), qr/Invalid value b in enum of type number/;
};

subtest 'Invalid schema with non Integer in  Integer Enum' => sub {
    like prepare('{"type":"object","properties":{"a":{"type":"integer","enum":["b"]}}}'),   qr/Invalid value b in enum of type integer/;
    like prepare('{"type":"object","properties":{"a":{"type":"integer","enum":[1.1]}}}'),   qr/Invalid value 1.1 in enum of type integer/;
    like prepare('{"type":"object","properties":{"a":{"type":"integer","enum":["1.2"]}}}'), qr/Invalid value 1.2 in enum of type integer/;
    like prepare('{"type":"object","properties":{"a":{"type":"integer","enum":[1.0]}}}'), qr/^$/, "OK, allow 1.0 as it is actually the same as 1???";
    like prepare('{"type":"object","properties":{"a":{"type":"integer","enum":["1.0"]}}}'), qr/Invalid value 1.0 in enum of type integer/;
};

subtest 'Object with Number' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"number"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    like check($fast_schema, '{"a":"b"}'), qr/Invalid number: b/;
    is check($fast_schema, '{"a":0}'),         '{"a":0}';
    is check($fast_schema, '{"a":"0"}'),       '{"a":0}';
    is check($fast_schema, '{"a":"-0"}'),      '{"a":0}';
    is check($fast_schema, '{"a":"0.0"}'),     '{"a":0.0}';
    is check($fast_schema, '{"a":"-0.0"}'),    '{"a":0.0}';
    is check($fast_schema, '{"a":1}'),         '{"a":1}';
    is check($fast_schema, '{"a":"1"}'),       '{"a":1}';
    is check($fast_schema, '{"a":-1}'),        '{"a":-1}';
    is check($fast_schema, '{"a":"-1"}'),      '{"a":-1}';
    is check($fast_schema, '{"a":0.1}'),       '{"a":0.1}';
    is check($fast_schema, '{"a":1.1}'),       '{"a":1.1}';
    is check($fast_schema, '{"a":"1.1"}'),     '{"a":1.1}';
    is check($fast_schema, '{"a":-1.1}'),      '{"a":-1.1}';
    is check($fast_schema, '{"a":"-1.1"}'),    '{"a":-1.1}';
    is check($fast_schema, '{"a":1.2e-07}'),   '{"a":1.2e-07}';
    is check($fast_schema, '{"a":"1.2e-07"}'), '{"a":1.2e-07}';
    is check($fast_schema, '{"a":1.2e-7}'),    '{"a":1.2e-07}';
    is check($fast_schema, '{"a":"1.2e-7"}'),  '{"a":1.2e-07}';
    is check($fast_schema, '{"a":1.2e-7}'),    '{"a":1.2e-07}';
    is check($fast_schema, '{"a":"1.2e-7"}'),  '{"a":1.2e-07}';
    is check($fast_schema, '{"a":-1.2e-7}'),   '{"a":-1.2e-07}';
    is check($fast_schema, '{"a":"-1.2e-7"}'), '{"a":-1.2e-07}';
    is check($fast_schema, '{"a":1.2e7}'),     '{"a":12000000}';
    is check($fast_schema, '{"a":"1.2e7"}'),   '{"a":12000000}';
    is check($fast_schema, '{"a":1.2e+7}'),    '{"a":12000000}';
    is check($fast_schema, '{"a":"1.2e+7"}'),  '{"a":12000000}';
    like check($fast_schema, '{"a":"0123"}'),  qr/Invalid number: 0123/;
    like check($fast_schema, '{"a":null}'),    qr/Expected number, found: null/;
    like check($fast_schema, '{"a":[1,2]}'),   qr/Expected number, found: Array/;
    like check($fast_schema, '{"a":{"a":1}}'), qr/Expected number, found: Object/;
    like check($fast_schema, '{"a":"๒"}'),     qr/Invalid number: ./, "This is a THAI DIGIT TWO";
    like check($fast_schema, '{"a":""}'),      qr/Invalid number:  /;
};

subtest 'Object with Number with range' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"number","minimum":2,"maximum":10}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    like check($fast_schema, '{"a":1}'),      qr/Value smaller than minimum \(2\): 1/;
    like check($fast_schema, '{"a":1.9999}'), qr/Value smaller than minimum \(2\): 1\.9999/;
    is check($fast_schema, '{"a":2}'),  '{"a":2}';
    is check($fast_schema, '{"a":4}'),  '{"a":4}';
    is check($fast_schema, '{"a":10}'), '{"a":10}';
    like check($fast_schema, '{"a":10.001}'), qr/Value bigger than maximum \(10\): 10\.001/;
};

subtest 'Object with Integer' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"integer"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";

    like check($fast_schema, '{"a":"b"}'), qr/Invalid integer: b/;
    is check($fast_schema, '{"a":0}'),    '{"a":0}';
    is check($fast_schema, '{"a":"0"}'),  '{"a":0}';
    is check($fast_schema, '{"a":"-0"}'), '{"a":0}';
    is check($fast_schema, '{"a":1}'),    '{"a":1}';
    is check($fast_schema, '{"a":"1"}'),  '{"a":1}';
    is check($fast_schema, '{"a":-1}'),   '{"a":-1}';
    is check($fast_schema, '{"a":"-1"}'), '{"a":-1}';
    like check($fast_schema, '{"a":1.2e-07}'),   qr/Invalid integer: 1.2e-07/;
    like check($fast_schema, '{"a":"1.2e-07"}'), qr/Invalid integer: 1.2e-07/;
    like check($fast_schema, '{"a":1.2e-7}'),    qr/Invalid integer: 1.2e-07/;
    like check($fast_schema, '{"a":"1.2e-7"}'),  qr/Invalid integer: 1.2e-7/;
    like check($fast_schema, '{"a":1.2e-7}'),    qr/Invalid integer: 1.2e-07/;
    like check($fast_schema, '{"a":"1.2e-7"}'),  qr/Invalid integer: 1.2e-7/;
    like check($fast_schema, '{"a":-1.2e-7}'),   qr/Invalid integer: -1.2e-07/;
    like check($fast_schema, '{"a":"-1.2e-7"}'), qr/Invalid integer: -1.2e-7/;
    is check($fast_schema, '{"a":1.2e7}'),    '{"a":12000000}';
    is check($fast_schema, '{"a":"1.2e7"}'),  '{"a":12000000}';
    is check($fast_schema, '{"a":1.2e+7}'),   '{"a":12000000}';
    is check($fast_schema, '{"a":"1.2e+7"}'), '{"a":12000000}';
    like check($fast_schema, '{"a":"0123"}'),  qr/Invalid integer: 0123/;
    like check($fast_schema, '{"a":1.1}'),     qr/Invalid integer: 1.1/;
    like check($fast_schema, '{"a":"1.0"}'),   qr/Invalid integer: 1.0/;
    like check($fast_schema, '{"a":null}'),    qr/Expected integer, found: null/;
    like check($fast_schema, '{"a":[1,2]}'),   qr/Expected integer, found: Array/;
    like check($fast_schema, '{"a":{"a":1}}'), qr/Expected integer, found: Object/;
    like check($fast_schema, '{"a":"๒"}'),     qr/Invalid integer: ./, "This is a THAI DIGIT TWO";
    like check($fast_schema, '{"a":""}'),      qr/Invalid integer:  /;
};

subtest 'Object with Integer with range' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"integer","minimum":2,"maximum":10}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    like check($fast_schema, '{"a":1}'), qr/Value smaller than minimum \(2\): 1/;
    is check($fast_schema, '{"a":2}'),  '{"a":2}';
    is check($fast_schema, '{"a":4}'),  '{"a":4}';
    is check($fast_schema, '{"a":10}'), '{"a":10}';
    like check($fast_schema, '{"a":11}'), qr/Value bigger than maximum \(10\): 11/;
};

subtest 'Object with Object' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"object","properties":{}}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":{}}'), '{"a":{}}';
    like check($fast_schema, '{"a":1}'),     qr/Expected object/;
    like check($fast_schema, '{"a":"1"}'),   qr/Expected object/;
    like check($fast_schema, '{"a":1.1}'),   qr/Expected object/;
    like check($fast_schema, '{"a":"1.1"}'), qr/Expected object/;
    like check($fast_schema, '{"a":null}'),  qr/Expected object, found: null/;
};

subtest 'Object with required' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","required":["a"],"properties":{"a":{"type":"number"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    like check($fast_schema, '{}'), qr/Missing element 'a'/;
    is check($fast_schema, '{"a":1}'), '{"a":1}';
};

subtest 'Object with Array with Number' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"array","items":{"type":"number"}}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    like check($fast_schema, '{"a":{"a":"b"}}'), qr/Expected array, found: Object/;
    like check($fast_schema, '{"a":1}'),         qr/Expected array, found: Scalar/;
    like check($fast_schema, '{"a":"a"}'),       qr/Expected array, found: Scalar/;
    is check($fast_schema, '{"a":[1.1]}'),         '{"a":[1.1]}';
    is check($fast_schema, '{"a":[1,2,3,4.1]}'),   '{"a":[1,2,3,4.1]}';
    is check($fast_schema, '{"a":[1,2,"3",4.1]}'), '{"a":[1,2,3,4.1]}';
    like check($fast_schema, '{"a":["a"]}'),       qr/Invalid number: a at: JSON Path: a::item_0/;
    like check($fast_schema, '{"a":[1,2,3,"a"]}'), qr/Invalid number: a at: JSON Path: a::item_3/;
};

subtest 'Object with Array with no item type' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"array"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    like check($fast_schema, '{"a":{"a":"b"}}'), qr/Expected array, found: Object/;
    like check($fast_schema, '{"a":1}'),         qr/Expected array, found: Scalar/;
    like check($fast_schema, '{"a":"a"}'),       qr/Expected array, found: Scalar/;
    is check($fast_schema, '{"a":[1.1]}'),         '{"a":[1.1]}';
    is check($fast_schema, '{"a":[1,2,3,4.1]}'),   '{"a":[1,2,3,4.1]}';
    is check($fast_schema, '{"a":[1,2,"3",4.1]}'), '{"a":[1,2,"3",4.1]}';
    is check($fast_schema, '{"a":["a"]}'),         '{"a":["a"]}';
    is check($fast_schema, '{"a":[1,2,3,"a"]}'),   '{"a":[1,2,3,"a"]}';
};

subtest 'Object with String Or Null' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":["string","null"]}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"b"}'),   '{"a":"b"}';
    is check($fast_schema, '{"a":1}'),     '{"a":"1"}';
    is check($fast_schema, '{"a":"1"}'),   '{"a":"1"}';
    is check($fast_schema, '{"a":1.1}'),   '{"a":"1.1"}';
    is check($fast_schema, '{"a":"1.1"}'), '{"a":"1.1"}';
    is check($fast_schema, '{"a":null}'),  '{"a":null}';
};

subtest 'Object without Required' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"},"c":{"type":"string"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"b"}'),                 '{"a":"b"}';
    is check($fast_schema, '{"a":"x","b":"y"}'),         '{"a":"x","b":"y"}';
    is check($fast_schema, '{"a":"x","b":"y","c":"z"}'), '{"a":"x","b":"y","c":"z"}';
};

subtest 'Object with Required' => sub {
    my ($fast_schema, $error) =
        prepare('{"type":"object","required":["a","b"],"properties":{"a":{"type":"string"},"b":{"type":"string"},"c":{"type":"string"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    like check($fast_schema, '{"a":"x"}'), qr/Missing element 'b' at: Top Level JSON/;
    is check($fast_schema, '{"a":"x","b":"y"}'),         '{"a":"x","b":"y"}';
    is check($fast_schema, '{"a":"x","b":"y","c":"z"}'), '{"a":"x","b":"y","c":"z"}';
};

subtest 'Object without Additional Properties and ignore' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","additionalProperties":false,"properties":{"a":{"type":"string"},"b":{"type":"string"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"b"}'),                 '{"a":"b"}';
    is check($fast_schema, '{"a":"x","b":"y"}'),         '{"a":"x","b":"y"}';
    is check($fast_schema, '{"a":"x","b":"y","c":"z"}'), '{"a":"x","b":"y","c":"z"}';
};

subtest 'Object with Additional Properties' => sub {
    my ($fast_schema, $error) =
        prepare('{"type":"object","additionalProperties":{"type":"integer"},"properties":{"a":{"type":"string"},"b":{"type":"string"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"b"}'),         '{"a":"b"}';
    is check($fast_schema, '{"a":"x","b":"y"}'), '{"a":"x","b":"y"}';
    like check($fast_schema, '{"a":"x","b":"y","c":"z"}'), qr/Invalid integer: z at: JSON Path: c/;
    is check($fast_schema, '{"a":"x","b":"y","c":"12"}'), '{"a":"x","b":"y","c":12}';
};

subtest 'Object with Additional Properties without schema' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"}}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    is check($fast_schema, '{"a":"b"}'),                  '{"a":"b"}';
    is check($fast_schema, '{"a":"x","b":"y"}'),          '{"a":"x","b":"y"}';
    is check($fast_schema, '{"a":"x","b":"y","c":"z"}'),  '{"a":"x","b":"y","c":"z"}';
    is check($fast_schema, '{"a":"x","b":"y","c":"12"}'), '{"a":"x","b":"y","c":"12"}';
};

subtest 'Object with only Additional Properties' => sub {
    my ($fast_schema, $error) = prepare('{"type":"object","additionalProperties":{"type":"integer"}}');
    is $error,         '',    "No error parsing schema";
    isnt $fast_schema, undef, "Parsed schema";
    like check($fast_schema, '{"a":"b"}'),         qr/Invalid integer: b at: JSON Path: a/;
    like check($fast_schema, '{"a":"b","b":"2"}'), qr/Invalid integer: b at: JSON Path: a/;
    is check($fast_schema, '{"a":"1","b":"2","c":"12"}'), '{"a":1,"b":2,"c":12}';

};

done_testing();

