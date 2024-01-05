use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep qw(cmp_bag);

use Locale::Country;
use List::Util qw(first any);

use Brands::Countries;
use BOM::Config;

my $server_routing_config = BOM::Config::mt5_server_routing();

subtest 'check mt5 routing countries with our countries' => sub {
    my @routed_countries = keys %{$server_routing_config->{real}};

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
subtest 'Check Platform 3' => sub {
    my @routed_countries = keys %{$server_routing_config->{real}};

    subtest 'Check Platform 3 Trader Server 1' => sub {
        my @platform_3_ts01_server_countries = qw/pk in nz bn mm kh tl id la ph sg th vn kr bd lk np bt mv tw mo cn jp/;

        my @p03_ts01_countries = grep {
            any { $_ eq 'p03_ts01' }
                $server_routing_config->{real}->{$_}->{synthetic}->{servers}->{standard}->@*
        } @routed_countries;

        is(scalar @platform_3_ts01_server_countries, scalar @p03_ts01_countries, "P03 TS01 has correct countries count");
        cmp_bag(\@platform_3_ts01_server_countries, \@p03_ts01_countries, "P03 TS01 has correct countries");
    };
};

done_testing();
