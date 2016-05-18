use strict;
use warnings;

use Test::Most;
use BOM::Product::ErrorStrings qw( format_error_string normalize_error_string );

subtest 'format_error_string' => sub {
    is(format_error_string(undef), undef, 'Undef static part yields undef');
    is(format_error_string(undef, 'dynamic' => 1), undef, '... even if the dynamic part has stuff');
    is(format_error_string('static bit'), 'static bit', 'Wholly static message is unchanged');
    is(format_error_string('static bit', 'bad dynamic bit'), undef, 'Unpaired dynamic part goes undef');
    is(
        format_error_string(
            'static bit',
            'min' => 1,
            'max' => 3,
        ),
        'static bit [min: 1] [max: 3]',
        'Things appear in the order provided'
    );
    is(
        format_error_string(
            'static bit',
            'min' => undef,
            'max' => 3,
        ),
        'static bit [min: undef] [max: 3]',
        '... and undef becomes a string'
    );
};

subtest 'normalize_error_string' => sub {
    is(normalize_error_string(format_error_string(undef)),        undef,        'Undef message yields undef');
    is(normalize_error_string(format_error_string('static bit')), 'static_bit', 'Wholly static message returned snake_cased');
    is(normalize_error_string(format_error_string('StaticBit')),  'static_bit', '.. even if it was camelCased before');
    is(
        normalize_error_string(
            format_error_string(
                'static bit',
                'min' => 1,
                'max' => 3,
            )
        ),
        'static_bit',
        '... even if dynamic bits were appended'
    );
    is(
        normalize_error_string('StaticBit [and: more] OtherStatic plus stuff'),
        'static_bit_other_static_plus_stuff',
        '.. and even if it is in a non-standard, but close format'
    );
};

done_testing;
