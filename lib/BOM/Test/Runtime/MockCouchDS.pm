package BOM::Test::Runtime::MockCouchDS;

use Moose;

has 'data' => (
    is => 'ro',
);

sub document {
    return shift->data;
}

__PACKAGE__->meta->make_immutable;

1;
