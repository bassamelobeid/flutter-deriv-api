package BOM::Product::Role::Vanilla;

use Moose::Role;
use Time::Duration::Concise;

sub is_binary {
    return 0;
}

1;
