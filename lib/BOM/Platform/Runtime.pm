package BOM::Platform::Runtime;

use Moose;
use feature 'state';

use App::Config::Chronicle;
use BOM::Platform::Chronicle;

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
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        setting_name     => 'binary',
    );
}

sub get_offerings_config {
    my $runtime = shift;

    $config_args->{suspend_trading}        = $runtime->app_config->system->suspend->trading;
    $config_args->{suspend_trades}         = $runtime->app_config->quants->underlyings->suspend_trades;
    $config_args->{suspend_buy}            = $runtime->app_config->quants->underlyings->suspend_buy;
    $config_args->{suspend_contract_types} = $runtime->app_config->quants->features->suspend_contract_types;

    $config_args->{disabled_markets} = $runtime->app_config->quants->markets->disabled;

    return $config_args;
}

__PACKAGE__->meta->make_immutable;
1;
