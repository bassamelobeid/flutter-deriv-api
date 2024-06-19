use strict;
use warnings;
use Test::More;
use Mojo::Exception;
use BOM::OAuth::Helper qw(strip_array_values);

subtest 'strip_array_values' => sub {
    subtest 'is able to extract values' => sub {
        is_deeply strip_array_values({
                key1 => ['1', '2'],
                key2 => 'value',
                key3 => []}
            ),
            {
            key1 => '2',
            key2 => 'value',
            key3 => ''
            };
    };

    subtest 'correct result with empty hash' => sub {
        is_deeply strip_array_values({}), {};

    };

    subtest 'correct result with no hash' => sub {
        is_deeply strip_array_values('not hash'), 'not hash';
    };
};

done_testing();
