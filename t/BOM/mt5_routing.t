use strict;
use warnings;

use Test::More;
use Test::Fatal;

use Locale::Country;
use List::Util qw(first);

use Brands::Countries;
use BOM::Config;

subtest 'check mt5 routing countries with our countries' => sub {
    my $server_routing_config = BOM::Config::mt5_server_routing();
    my @routed_countries      = keys %{$server_routing_config->{real}};

    my $brand_country = Brands::Countries->new();
    my $configs       = $brand_country->countries_list;

    my @allowed_countries = ();
    foreach my $country_code (sort keys %$configs) {
        next if $brand_country->restricted_country($country_code);
        push @allowed_countries, $country_code;
    }

    foreach my $country_code (@allowed_countries) {
        my $exists = first { $country_code eq $_ } @routed_countries;
        ok($exists, "$country_code exists in routing config");
    }

};

done_testing();
