package BOM::Config::Runtime;

use Moose;
use feature 'state';

use App::Config::Chronicle;
use BOM::Config::Chronicle;
use BOM::Config;
use List::Util qw(uniq);

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
        definition_yml   => '/home/git/regentmarkets/bom-config/share/app_config_definitions.yml',
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        setting_name     => BOM::Config->brand->name,
    );
}

sub get_offerings_config {
    my ($runtime, $action, $exclude_suspend) = @_;

    # default to buy action
    $action //= 'buy';

    die 'unsupported action ' . $action unless $action eq 'buy' or $action eq 'sell';

    my $config = {
        suspend_trading => $runtime->app_config->system->suspend->trading,
        loaded_revision => $runtime->app_config->loaded_revision // 0,
        action          => $action,
    };

    $config->{loaded_revision} = 0 if $exclude_suspend;

    return $config if $exclude_suspend;

    my $quants_config = $runtime->app_config->quants;

    if ($action eq 'buy') {
        $config->{suspend_underlying_symbols} = [uniq(@{$quants_config->underlyings->suspend_buy}, @{$quants_config->underlyings->suspend_trades})];
        $config->{suspend_markets}            = [uniq(@{$quants_config->markets->suspend_buy},     @{$quants_config->markets->suspend_trades})];
        $config->{suspend_contract_types} = [uniq(@{$quants_config->contract_types->suspend_buy}, @{$quants_config->contract_types->suspend_trades})];
    } elsif ($action eq 'sell') {
        $config->{suspend_underlying_symbols} = [uniq(@{$quants_config->underlyings->suspend_trades})];
        $config->{suspend_markets}            = [uniq(@{$quants_config->markets->suspend_trades})];
        $config->{suspend_contract_types}     = [uniq(@{$quants_config->contract_types->suspend_trades})];
    }

    return $config;
}

__PACKAGE__->meta->make_immutable;
1;
