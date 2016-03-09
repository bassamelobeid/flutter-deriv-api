package BOM::Test::Runtime::MockDS;

use Moose;

has 'data' => (
    is => 'ro',
);

sub document {
    return shift->data;
}

__PACKAGE__->meta->make_immutable;

1;
