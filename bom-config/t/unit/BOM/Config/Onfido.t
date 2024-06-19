use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;

use Business::Config;
use BOM::Config::Onfido;

subtest 'is_country_supported' => sub {
    my ($mocked_country_details, $mocked_country_code2code, $mocked_disabled_country, $expected);
    my $mocked_onfido = Test::MockModule->new("BOM::Config::Onfido");
    $mocked_onfido->redefine("country_code2code"    => sub { return $mocked_country_code2code });
    $mocked_onfido->redefine("_get_country_details" => sub { return $mocked_country_details });
    $mocked_onfido->redefine("is_disabled_country"  => sub { return $mocked_disabled_country });

    $expected                = 0;
    $mocked_disabled_country = 1;
    my $country_code = "ao";
    is(BOM::Config::Onfido::is_country_supported($country_code), $expected, "Country is disabled");

    $expected                 = 1;
    $mocked_disabled_country  = 0;
    $country_code             = "ao";
    $mocked_country_code2code = "ao";
    $mocked_country_details   = {
        "AO" => {
            "country_code"     => "AO",
            "country_grouping" => "Asia",
            "country_name"     => "Aola",
            "doc_types_list"   => ["Passport", "National Identity Card"]}};
    is(BOM::Config::Onfido::is_country_supported($country_code), $expected, "Country supports multiple doc types");

    $expected               = 0;
    $mocked_country_details = {
        "AO" => {
            "country_code"     => "AO",
            "country_grouping" => "Asia",
            "country_name"     => "Aola",
            "doc_types_list"   => undef
        }};
    is(BOM::Config::Onfido::is_country_supported($country_code), $expected, "Country has no doc types");

    $expected               = 0;
    $mocked_country_details = {
        "AO" => {
            "country_code"     => "AO",
            "country_grouping" => "Asia",
            "country_name"     => "Aola",
            "doc_types_list"   => []}};
    is(BOM::Config::Onfido::is_country_supported($country_code), $expected, "Country has no doc types");

    $expected               = 0;
    $mocked_country_details = {
        "AO" => {
            "country_code"     => "AO",
            "country_grouping" => "Asia",
            "country_name"     => "Aola"
        }};
    is(BOM::Config::Onfido::is_country_supported($country_code), $expected, "Country has no doc types");
    $mocked_onfido->unmock_all();
};

subtest 'is_disabled_country' => sub {
    my $mocked_disabled_countries = {
        ao => 1,
    };

    my $mocked_config = Test::MockModule->new("Business::Config");
    $mocked_config->redefine("onfido_disabled_countries" => sub { return $mocked_disabled_countries });

    is(BOM::Config::Onfido::is_disabled_country('ao'), 1, "Country is disabled");
    is(BOM::Config::Onfido::is_disabled_country('ac'), 0, "Country is not disabled");

    $mocked_disabled_countries = {
        ao => 0,
    };

    is(BOM::Config::Onfido::is_disabled_country('ao'), 0, "Country is not disabled");
    is(BOM::Config::Onfido::is_disabled_country('ac'), 0, "Country is not disabled");

    $mocked_disabled_countries = {
        ao => 0,
        ac => 1
    };

    is(BOM::Config::Onfido::is_disabled_country('ao'), 0, "Country is not disabled");
    is(BOM::Config::Onfido::is_disabled_country('ac'), 1, "Country is disabled");

    $mocked_disabled_countries = {};

    is(BOM::Config::Onfido::is_disabled_country('ao'), 0, "Country is not disabled");
    is(BOM::Config::Onfido::is_disabled_country('ac'), 0, "Country is not disabled");

    $mocked_disabled_countries = {
        ao => 1,
        ac => 1
    };

    is(BOM::Config::Onfido::is_disabled_country('ao'), 1, "Country is disabled");
    is(BOM::Config::Onfido::is_disabled_country('ac'), 1, "Country is disabled");
};

subtest 'supported_documents_for_country' => sub {
    my ($mocked_country_details, $mocked_country_code2code, $expected);
    my $mocked_onfido = Test::MockModule->new("BOM::Config::Onfido");
    $mocked_onfido->redefine("country_code2code"    => sub { return $mocked_country_code2code });
    $mocked_onfido->redefine("_get_country_details" => sub { return $mocked_country_details });

    $expected                 = [];
    $mocked_country_code2code = "ao";
    is_deeply(BOM::Config::Onfido::supported_documents_for_country(), $expected, "Country code is not specified");

    my $country_code = "ao";
    $mocked_country_details = {
        "AO" => {
            "country_code"     => "AO",
            "country_grouping" => "Asia",
            "country_name"     => "Aola",
            "doc_types_list"   => undef,
        }};
    is_deeply(BOM::Config::Onfido::supported_documents_for_country($country_code), $expected, "Doc types are not specified");

    $expected               = ["Passport", "Voter ID"];
    $country_code           = "ao";
    $mocked_country_details = {
        "AO" => {
            "country_code"     => "AO",
            "country_grouping" => "Asia",
            "country_name"     => "Aola",
            "doc_types_list"   => ["Passport", "Voter ID"],
        }};
    is_deeply(BOM::Config::Onfido::supported_documents_for_country($country_code), $expected, "Doc types list is not empty");
};

done_testing;
