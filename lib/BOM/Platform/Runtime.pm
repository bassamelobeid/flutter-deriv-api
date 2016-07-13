package BOM::Platform::Runtime;

use Moose;
use feature 'state';

use BOM::Platform::Runtime::AppConfig;

has 'app_config' => (
    is         => 'ro',
    lazy_build => 1,
);

my $instance;

BEGIN {
    $instance = __PACKAGE__->new;
}

sub instance {
    my ($class, $new) = @_;
    $instance = $new if (defined $new);

    return $instance;
}

sub _build_app_config {
    my $self = shift;
    return BOM::Platform::Runtime::AppConfig->new();
}

__PACKAGE__->meta->make_immutable;
1;
