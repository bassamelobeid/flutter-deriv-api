package BOM::Platform::Runtime;

use Moose;
use feature 'state';

use App::Config::Chronicle;
use BOM::System::Chronicle;

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
    return App::Config::Chronicle->new(
        definition_yml   => '/home/git/regentmarkets/bom-platform/config/app_config_definitions.yml',
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        setting_name     => 'binary',
    );
}

__PACKAGE__->meta->make_immutable;
1;
