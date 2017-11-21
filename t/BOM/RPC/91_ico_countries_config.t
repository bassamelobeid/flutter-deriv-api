use strict;
use warnings;

use Test::More;
use BOM::RPC::v3::Static;
use Brands;

my $countries_instance = Brands->new(name => 'binary')->countries_instance;

subtest 'ico_countries_config' => sub {
    my $res                  = BOM::RPC::v3::Static::ico_status();
    my $ico_countries_config = $res->{ico_countries_config};
    my $professional         = $ico_countries_config->{professional};
    my $restricted           = $ico_countries_config->{restricted};

    is_deeply $restricted,   [$countries_instance->ico_countries_by_investor('none')],         'Restricted countries';
    is_deeply $professional, [$countries_instance->ico_countries_by_investor('professional')], 'Professional countries';
};

done_testing();
