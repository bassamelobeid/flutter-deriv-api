use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use BOM::Config::Runtime;
use Test::MockModule;
use BOM::Platform::Utility;

my %idv = (
    'country'       => 'ng',
    'provider'      => 'smile_identity',
    'document_type' => 'divers_license'
);

subtest 'is idv disabled' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    is(BOM::Platform::Utility::is_idv_disabled(%idv), 1, "Should return 1 if IDV is disabled");
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);
    is(BOM::Platform::Utility::is_idv_disabled(%idv), 0, "Should return 0 if IDV is enabled");

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_countries([qw(ng)]);
    is(BOM::Platform::Utility::is_idv_disabled(%idv), 1, "Should return 1 if IDV country is disabled");
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_countries([qw( )]);
    is(BOM::Platform::Utility::is_idv_disabled(%idv), 0, "Should return 0 if IDV country is enabled");

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw(smile_identity)]);
    is(BOM::Platform::Utility::is_idv_disabled(%idv), 1, "Should return 1 if IDV provider is disabled");
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw( )]);
    is(BOM::Platform::Utility::is_idv_disabled(%idv), 0, "Should return 0 if IDV provider is enabled");

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(ng:divers_license)]);
    is(BOM::Platform::Utility::is_idv_disabled(%idv), 1, "Should return 1 if IDV document_type is disabled");
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(in:drivers_license)]);
    is(BOM::Platform::Utility::is_idv_disabled(%idv), 0, "Should return 0 if IDV document_type is enabled");
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw( )]);

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(zw:national_id)]);
    is(BOM::Platform::Utility::is_idv_disabled('country' => 'zw'), 1, "Country should be disabled if only supported document is disabled");
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw( )]);

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(ng:drivers_license ng:nin_slip)]);
    is(BOM::Platform::Utility::is_idv_disabled('country' => 'ng'), 1, "Country should be disabled if all supported documents are disabled");
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw( )]);
};

subtest 'has idv' => sub {
    my $mock_country_configs = Test::MockModule->new('Brands::Countries');
    $mock_country_configs->mock(
        is_idv_supported => sub {
            my (undef, $country) = @_;

            return 1 if ($country eq 'ng');
            return 0;
        });
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    is(BOM::Platform::Utility::has_idv(%idv), 0, "Should return 0 if IDV is disabled and supported");
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);
    is(BOM::Platform::Utility::has_idv(%idv), 1, "Should return 1 if IDV is not disabled and supported");
    $mock_country_configs->mock(
        is_idv_supported => sub {
            my (undef, $country) = @_;

            return 1 if ($country eq 'ne');
            return 0;
        });
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    is(BOM::Platform::Utility::has_idv(%idv), 0, "Should return 0 if IDV is disabled and not supported");
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);
    is(BOM::Platform::Utility::has_idv(%idv), 0, "Should return 0 if IDV is not disabled and not supported");
};

done_testing();

