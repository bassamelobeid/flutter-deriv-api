use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;

use BOM::Config::Compliance;

subtest 'get_risk_thresholds' => sub {
    throws_ok { BOM::Config::Compliance->get_risk_thresholds() } qr/Threshold type is missing/, 'Threshold type not passed in as argument';

    my $invalid_threshold_type = "AMD";
    throws_ok { BOM::Config::Compliance->get_risk_thresholds($invalid_threshold_type) } qr/Invalid threshold type $invalid_threshold_type/,
        'Un-supported threshold type is used';

    my $instance          = BOM::Config::Runtime->instance;
    my $mocked_instance   = Test::MockObject->new($instance);
    my $mocked_app_config = Test::MockObject->new();

    $mocked_instance->mock("app_config" => sub { return $mocked_app_config });

    my $mocked_compliance_config =
        '{"CR": {"yearly_standard": 10000, "yearly_high": 20000}, "MF": {"yearly_standard": 10000, "yearly_high": 20000} }';
    my $mocked_global_revision = 1;
    $mocked_app_config->mock("get"             => sub { $mocked_compliance_config });
    $mocked_app_config->mock("global_revision" => sub { $mocked_global_revision });
    my $expected = {
        CR => {
            yearly_standard => 10000,
            yearly_high     => 20000
        },
        MF => {
            yearly_standard => 10000,
            yearly_high     => 20000
        },
        revision => $mocked_global_revision
    };
    is_deeply(BOM::Config::Compliance->get_risk_thresholds("aml"), $expected, "supported risk type is specified as argument");
};

subtest 'validate_risk_thresholds' => sub {
    my $input_args = {
        CR => {
            yearly_standard => 10000,
            yearly_high     => 20000
        },
        MF => {
            yearly_standard => 10000,
            yearly_high     => 20000
        },
        revision => 1
    };
    my $expected = {
        CR => {
            yearly_standard => '10000.00',
            yearly_high     => '20000.00'
        },
        MF => {
            yearly_standard => '10000.00',
            yearly_high     => '20000.00'
        },
        revision => 1
    };
    is_deeply(BOM::Config::Compliance->validate_risk_thresholds(%$input_args), $expected, "Values are whole numbers");

    $input_args = {
        CR => {
            yearly_standard => '10000.745',
            yearly_high     => '20000.251'
        },
        MF => {
            yearly_standard => '10000.10',
            yearly_high     => '20000.60'
        },
        revision => 1
    };
    $expected = {
        CR => {
            yearly_standard => '10000.75',
            yearly_high     => '20000.25'
        },
        MF => {
            yearly_standard => '10000.10',
            yearly_high     => '20000.60'
        },
        revision => 1
    };
    is_deeply(BOM::Config::Compliance->validate_risk_thresholds(%$input_args), $expected, "Rounding off floating point values");

    $input_args = {
        CR => {
            yearly_standard => 'not a numeric value',
            yearly_high     => '20000.251'
        },
        MF => {
            yearly_standard => '10000.10',
            yearly_high     => '20000.60'
        },
        revision => 1
    };
    $expected = "Invalid numeric value";
    throws_ok { BOM::Config::Compliance->validate_risk_thresholds(%$input_args) } qr/$expected/, "Input contained non numeric value";

    $input_args = {
        CR => {
            yearly_standard => '30000',
            yearly_high     => '20000.251'
        },
        MF => {
            yearly_standard => '30000',
            yearly_high     => '20000.60'
        },
        revision => 1
    };
    $expected = "Yearly Standard threshold is higher than Yearly High Risk threshold";
    throws_ok { BOM::Config::Compliance->validate_risk_thresholds(%$input_args) } qr/$expected/,
        "Standard threshold is higher than high risk threshold";
};

subtest 'get_jurisdiction_risk_rating' => sub {
    my $instance          = BOM::Config::Runtime->instance;
    my $mocked_instance   = Test::MockObject->new($instance);
    my $mocked_app_config = Test::MockObject->new();

    $mocked_instance->mock("app_config" => sub { return $mocked_app_config });
    my $mocked_compliance_config = '{"standard":["c","d","a","b"], "high":["a","b","d","c"]}';
    my $mocked_global_revision   = 1;
    $mocked_app_config->mock("get"             => sub { $mocked_compliance_config });
    $mocked_app_config->mock("global_revision" => sub { $mocked_global_revision });

    my $expected = {
        standard => ["a", "b", "c", "d"],
        high     => ["a", "b", "c", "d"],
        revision => $mocked_global_revision
    };
    is_deeply(BOM::Config::Compliance->get_jurisdiction_risk_rating(), $expected, "countries are sorted correctly");
};

subtest 'validate_jurisdiction_risk_rating' => sub {
    my $mocked_global_revision = 1;
    my $compliance_obj         = BOM::Config::Compliance->new();
    my $mock_complaince        = Test::MockModule->new(ref $compliance_obj->_countries)->redefine("country_from_code", 1);

    my $input_args = {
        standard => ["e", "b", "a"],
        high     => ["d", "c", "h", "g"],
        revision => $mocked_global_revision
    };
    my $expected = {
        standard => ["a", "b", "e"],
        high     => ["c", "d", "g", "h"],
    };
    is_deeply($compliance_obj->validate_jurisdiction_risk_rating(%$input_args), $expected, "Countries are sorted correctly");

    $input_args = {
        standard => ["a", "b", "c"],
        high     => ["b"],
        revision => $mocked_global_revision
    };
    $expected = "Duplicate country found:";
    throws_ok { $compliance_obj->validate_jurisdiction_risk_rating(%$input_args) } qr/$expected/, "duplicate country";

    $input_args = {
        standard => ["e", "b", "a"],
        high     => ["d", "c", "h", "g"],
        revision => $mocked_global_revision
    };
    $mock_complaince->redefine("country_from_code", 0);
    $expected = "Invalid country code";
    throws_ok { $compliance_obj->validate_jurisdiction_risk_rating(%$input_args) } qr/$expected/, "Invalid country code is provided";
    $mock_complaince->unmock_all();
};

done_testing;
