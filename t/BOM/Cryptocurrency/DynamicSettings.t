use strict;
use warnings;

use Test::Deep;
use Test::More;

use JSON::MaybeXS;
use BOM::Cryptocurrency::DynamicSettings;

subtest "normalize_settings_data" => sub {
    my $settings = {
        revision => 0,
        settings => {
            'dummy.int' => {
                description   => 'dummy description',
                key_type      => 'static',
                data_type     => 'Int',
                default_value => 0,
                current_value => 1,
            },
            'dummy.ArrayRef' => {
                description   => 'dummy description',
                key_type      => 'dynamic',
                data_type     => 'ArrayRef',
                default_value => ['BTC', 'ETH'],
                current_value => ['BTC'],
            },
        },
    };

    my $expected_response = {
        'settings' => {
            'dummy' => {
                'dummy.ArrayRef' => {
                    'leaf' => {
                        'disabled'      => 0,
                        'description'   => 'dummy description',
                        'value'         => 'BTC',
                        'default_value' => 'BTC,ETH',
                        'default'       => '',
                        'type'          => 'ArrayRef',
                        'name'          => 'dummy.ArrayRef'
                    }
                },
                'dummy.int' => {
                    'leaf' => {
                        'disabled'      => 1,
                        'description'   => 'dummy description',
                        'value'         => 1,
                        'type'          => 'Int',
                        'default_value' => 0,
                        'default'       => '',
                        'name'          => 'dummy.int',
                    },
                },
            },
        },
        'setting_revision' => 0,
    };

    cmp_deeply BOM::Cryptocurrency::DynamicSettings::normalize_settings_data($settings), $expected_response, 'Get normalized setting data';
};

subtest "textify_obj" => sub {
    is BOM::Cryptocurrency::DynamicSettings::textify_obj('ArrayRef', ['BTC', 'ETH']), 'BTC,ETH', 'Convert the array value to string';
    is BOM::Cryptocurrency::DynamicSettings::textify_obj('Int',      1),              1,         'Return same value for non array value';
};

subtest "get_display_value" => sub {
    subtest "Data type - Bool" => sub {
        subtest "undefined value" => sub {
            is BOM::Cryptocurrency::DynamicSettings::get_display_value(undef, 'Bool'), 'false', 'Get false for undef boolean value';
        };

        subtest "false value" => sub {
            for my $value (qw/no n 0 false/) {
                is BOM::Cryptocurrency::DynamicSettings::get_display_value($value, 'Bool'), 'false', "Get false for $value boolean value";
            }
        };

        subtest "true value" => sub {
            for my $value (qw/yes y 1 true on/) {
                is BOM::Cryptocurrency::DynamicSettings::get_display_value($value, 'Bool'), 'true', "Get true for $value boolean value";
            }
        };

        subtest "unsupported value" => sub {
            is BOM::Cryptocurrency::DynamicSettings::get_display_value('dummy', 'Bool'), 'dummy', "Get same passed value";
        };
    };

    subtest "Data type - ArrayRef" => sub {
        subtest "undefined value" => sub {
            is BOM::Cryptocurrency::DynamicSettings::get_display_value(undef, 'ArrayRef'), '', 'Get "" for undef ArrayRef value';
        };

        subtest "ArrayRef value" => sub {
            is BOM::Cryptocurrency::DynamicSettings::get_display_value([1, 2, 3], 'ArrayRef'), '1,2,3', 'Convert the ArrayRef value to string';
        };

        subtest "string value - comma" => sub {
            is BOM::Cryptocurrency::DynamicSettings::get_display_value('BTC, ETH', 'ArrayRef'), 'BTC,ETH', 'Remove the white space';
        };

        subtest "string value - space" => sub {
            is BOM::Cryptocurrency::DynamicSettings::get_display_value('BTC ETH', 'ArrayRef'), 'BTC, ETH', 'Separate by comma';
        };
    };

    subtest "Data type - json_string" => sub {
        subtest "undefined value" => sub {
            is BOM::Cryptocurrency::DynamicSettings::get_display_value(undef, 'json_string'), undef, 'return undef for undef value';
        };

        subtest "correct value" => sub {
            my $expected_value = JSON::MaybeXS->new(
                pretty    => 1,
                canonical => 1,
            )->encode({BTC => 1});
            is BOM::Cryptocurrency::DynamicSettings::get_display_value('{"BTC": 1}', 'json_string'), $expected_value, 'Correct json value';
        };
    };

    subtest "Data type - Num" => sub {
        is BOM::Cryptocurrency::DynamicSettings::get_display_value('0.1', 'Num'), 0.1, 'Correct Num value';
    };

    subtest "Data type - Int" => sub {
        is BOM::Cryptocurrency::DynamicSettings::get_display_value('1', 'Int'), 1, 'Correct Int value';
    };

    subtest "Unsupported data type" => sub {
        is BOM::Cryptocurrency::DynamicSettings::get_display_value(1, 'dummy'), 1, 'Return the same value';
    };
};

done_testing;
