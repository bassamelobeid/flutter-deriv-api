package BOM::Product::Role::Vanilla;

use Moose::Role;
use Time::Duration::Concise;

override is_binary => sub {
    return 0;
};

1;
