use strict;
use warnings;

use YAML::XS qw(DumpFile LoadFile);
use JSON::MaybeXS;
use Getopt::Long;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

# Imports P2P payment methods from a yaml file.
# if -y option is provided, will rewrite the p2p_payment_methods.yml file in bom-config/share.

GetOptions('y|yml' => \my $update_yml);

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my $data    = LoadFile($ARGV[0]);
my $methods = BOM::Config::p2p_payment_methods();

if ($update_yml) {
    for my $method (keys %$data) {
        $methods->{$method}{display_name} = $data->{$method}{name};

        unless (exists $methods->{$method}{fields}) {
            # default field named with method
            $methods->{$method}{fields}{account}{display_name} = $data->{$method}{name};
        }
    }

    DumpFile('/home/git/regentmarkets/bom-config/share/p2p_payment_methods.yml', $methods);
}

my $country_config = JSON::MaybeXS->new->decode($app_config->get('payments.p2p.payment_method_countries'));

for my $method (sort keys %$data) {
    next unless exists $methods->{$method};
    my $def = $data->{$method};
    $country_config->{$method}{mode}      = $def->{exclude_countries} ? 'exclude' : 'include';
    $country_config->{$method}{countries} = [sort map { lc($_) } $def->{country}->@*] if $def->{country};
}

$app_config->set({'payments.p2p.payment_method_countries', JSON::MaybeXS->new(canonical => 1)->encode($country_config)});
