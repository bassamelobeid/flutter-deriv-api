package BOM::Test::Helper::UserService;

use strict;
use warnings;

use UUID::Tiny;

sub get_context {
    return {
        'correlation_id' => UUID::Tiny::create_UUID_as_string(UUID::Tiny::UUID_V4),
        'auth_token'     => 'Test Token, just for testing',
    };
}

1;
