use Test::Most 0.22 (tests => 7);
use Test::NoWarnings;

use BOM::Platform::Runtime::AppConfig::Attribute;
use BOM::Utility::HashDotNotation;

throws_ok {
    BOM::Platform::Runtime::AppConfig::Attribute->new(
        name        => 'test',
        parent_path => 'apperturescience'
    );
}
qr/Attribute \(data_set\) is required/;

throws_ok {
    BOM::Platform::Runtime::AppConfig::Attribute->new(
        name        => 'suspend_trades',
        parent_path => 'quants.underlyings',
        data_set    => {version => 1},
        definition  => {
            isa     => 'ArrayRef',
            default => 'x',
        },
    )->build;
}
qr/ArrayRef/;

throws_ok {
    BOM::Platform::Runtime::AppConfig::Attribute->new(
        name        => 'json_string',
        parent_path => 'validation.tests',
        data_set    => {version => 1},
        definition  => {
            isa     => 'json_string',
            default => 'x',
        },
    )->build;
}
qr/JSON/;

subtest 'get' => sub {
    subtest 'default' => sub {
        my $attribute = BOM::Platform::Runtime::AppConfig::Attribute->new(
            name        => 'get',
            parent_path => 'tests',
            data_set    => {version => 1},
            definition  => {
                isa     => 'Str',
                default => 'a',
            },
        )->build;

        ok $attribute, "Attribute created";
        is $attribute->path,    'tests.get';
        is $attribute->value,   'a', 'Got from default';
        is $attribute->version, 1, 'Version set to data_set version';
    };

    subtest 'from app_config' => sub {
        my $data = {tests => {get => 'b'}};
        my $app_config = BOM::Utility::HashDotNotation->new(data => $data);

        my $attribute = BOM::Platform::Runtime::AppConfig::Attribute->new(
            name        => 'get',
            parent_path => 'tests',
            data_set    => {
                version    => 1,
                app_config => $app_config
            },
            definition => {
                isa     => 'Str',
                default => 'a'
            },
        )->build;

        ok $attribute, "Attribute created";
        ok !$attribute->version, 'Version not yet set';
        is $attribute->path,    'tests.get';
        is $attribute->value,   'b', 'Got from app_config';
        is $attribute->version, 1, 'Version set to data_set version';
    };
};

subtest 'set' => sub {
    subtest 'set after access' => sub {
        my $data = {tests => {get => 'b'}};
        my $app_config = BOM::Utility::HashDotNotation->new(data => $data);

        my $data_set = {
            version    => 1,
            app_config => $app_config
        };
        my $attribute = BOM::Platform::Runtime::AppConfig::Attribute->new(
            name        => 'get',
            parent_path => 'tests',
            data_set    => {
                version    => 1,
                app_config => $app_config,
            },
            definition => {
                isa     => 'Str',
                default => 'a'
            },
        )->build;

        ok $attribute, "Attribute created";
        is $attribute->path, 'tests.get';
        is $attribute->value, 'b', 'Got b';

        $attribute->value('d');
        is $attribute->value,   'd', 'Got d';
        is $attribute->version, 1,   'Updates current version of the build to set value';
    };

    subtest 'set before access' => sub {
        my $data = {tests => {get => 'b'}};
        my $app_config = BOM::Utility::HashDotNotation->new(data => $data);

        my $data_set = {
            version    => 1,
            app_config => $app_config
        };
        my $attribute = BOM::Platform::Runtime::AppConfig::Attribute->new(
            name        => 'get',
            parent_path => 'tests',
            data_set    => {
                version    => 1,
                app_config => $app_config,
            },
            definition => {
                isa     => 'Str',
                default => 'a'
            },
        )->build;

        $attribute->value('d');
        is $attribute->value,   'd', 'Got d';
        is $attribute->version, 1,   'Updates current version of the build to set value';
    };
};

subtest 'set validation' => sub {
    my $attribute = BOM::Platform::Runtime::AppConfig::Attribute->new(
        name        => 'array',
        parent_path => 'valudations.test',
        data_set    => {version => 1},
        definition  => {
            isa     => 'ArrayRef',
            default => ['1', '2', '3'],
        },
    )->build;

    throws_ok { $attribute->value('a'); } qr/ArrayRef/;
};
