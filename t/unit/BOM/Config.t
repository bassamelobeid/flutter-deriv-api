use strict;
use warnings;
use BOM::Config;
use Test::More;
use YAML::XS;
use lib qw(/home/git/regentmarkets/bom-config/t/lib/);
use YamlTestStructure;

my $test_parameters = YAML::XS::LoadFile("/home/git/regentmarkets/bom-config/t/unit/BOM/config_test_parameters.yml");
for my $test_parameter (@$test_parameters) {
    subtest "Test YAML return correct structure for $test_parameter->{name}", \&YamlTestStructure::yaml_structure_validator, $test_parameter->{args};
}

done_testing;
