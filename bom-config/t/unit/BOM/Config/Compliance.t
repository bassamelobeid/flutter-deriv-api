use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::MockModule;
use Test::MockObject;

use BOM::Config::Compliance;

subtest 'get_risk_thresholds' => sub {
    my $mocked_instance   = Test::MockObject->new(BOM::Config::Runtime->instance);
    my $mocked_app_config = Test::MockObject->new();

    $mocked_instance->mock("app_config" => sub { return $mocked_app_config });

    my $mocked_compliance_config =
        '{"CR": {"yearly_standard": 10000, "yearly_high": 20000}, "MF": {"yearly_standard": 10000, "yearly_high": 20000}, "bvi": {"yearly_standard": 100, "yearly_high": 200}}';
    my $mocked_global_revision = 1;
    $mocked_app_config->mock("get"             => sub { $mocked_compliance_config });
    $mocked_app_config->mock("global_revision" => sub { $mocked_global_revision });
    my $expected = {
        svg => {
            yearly_standard => 10000,
            yearly_high     => 20000
        },
        maltainvest => {
            yearly_standard => 10000,
            yearly_high     => 20000
        },
        revision => $mocked_global_revision
    };

    like exception { BOM::Config::Compliance->get_risk_thresholds() }, qr/Threshold type is missing/, 'Threshold type is required';

    is_deeply(
        BOM::Config::Compliance->get_risk_thresholds('aml'),
        {
            svg => {
                yearly_standard => 10000,
                yearly_high     => 20000
            },
            maltainvest => {
                yearly_standard => 10000,
                yearly_high     => 20000
            },
            revision => $mocked_global_revision
        },
        "Broker code is converted to short-name"
    );

    is_deeply(
        BOM::Config::Compliance->get_risk_thresholds('mt5'),
        {
            bvi => {
                yearly_standard => 100,
                yearly_high     => 200
            },
            labuan => {
                yearly_standard => undef,
                yearly_high     => undef,
            },
            vanuatu => {
                yearly_standard => undef,
                yearly_high     => undef,
            },
            revision => $mocked_global_revision
        },
        'MT5 thresholds are correct'
    );
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
        svg => {
            yearly_standard => '10000.00',
            yearly_high     => '20000.00'
        },
        maltainvest => {
            yearly_standard => '10000.00',
            yearly_high     => '20000.00'
        },
        revision => 1
    };
    is_deeply(BOM::Config::Compliance->validate_risk_thresholds('aml', %$input_args), $expected, "Values are finacial-rounded");

    $input_args = {
        svg => {
            yearly_standard => '10000.745',
            yearly_high     => '20000.251'
        },
        maltainvest => {
            yearly_standard => '10000.10',
            yearly_high     => '20000.60'
        },
        revision => 1
    };
    $expected = {
        svg => {
            yearly_standard => '10000.75',
            yearly_high     => '20000.25'
        },
        maltainvest => {
            yearly_standard => '10000.10',
            yearly_high     => '20000.60'
        },
        revision => 1
    };
    is_deeply(BOM::Config::Compliance->validate_risk_thresholds('aml', %$input_args), $expected, "Rounding off floating point values");

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
    like exception { BOM::Config::Compliance->validate_risk_thresholds('aml', %$input_args) }, qr/$expected/, "Input contained non numeric value";

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
    like exception { BOM::Config::Compliance->validate_risk_thresholds('aml', %$input_args) }, qr/$expected/,
        "Standard threshold is higher than high risk threshold";
};

subtest 'get_jurisdiction_risk_rating' => sub {
    my $mocked_jurisdition_config;
    my $mocked_global_revision = 1;

    my $mocked_instance   = Test::MockObject->new(BOM::Config::Runtime->instance);
    my $mocked_app_config = Test::MockObject->new();

    $mocked_instance->mock("app_config" => sub { return $mocked_app_config });
    $mocked_app_config->mock("get"             => sub { $mocked_jurisdition_config });
    $mocked_app_config->mock("global_revision" => sub { $mocked_global_revision });

    my $mock_landing_company = Test::MockModule->new('LandingCompany');
    $mock_landing_company->redefine(
        risk_settings => sub {
            my $lc = shift;

            return [qw/aml_jurisdiction/] if $lc->short eq 'maltainvest';
            return [qw/mt5_jurisdiction/] if $lc->short =~ qr/labuan|bvi/;
            return [];
        });

    $mocked_jurisdition_config = '{"maltainvest": {"standard":["c","d"], "high":["a","b"]}, "labuan": {"high":["e","f"], "restricted": ["g"]} }';
    my $expected = {
        maltainvest => {
            standard   => ["c", "d"],
            high       => ["a", "b"],
            restricted => []
        },
        labuan => {
            standard   => [],
            high       => ["e", "f"],
            restricted => ["g"]
        },
        bvi => {
            standard   => [],
            high       => [],
            restricted => []
        },
        revision => $mocked_global_revision
    };
    like exception { BOM::Config::Compliance->get_jurisdiction_risk_rating() }, qr/Threshold type is missing/, 'Threshold type is required';
    cmp_deeply(
        BOM::Config::Compliance->get_jurisdiction_risk_rating('aml'),
        {
            maltainvest => {
                standard   => [qw/c d/],
                high       => [qw/a b/],
                restricted => []
            },
            revision => $mocked_global_revision
        },
        "Correct landing companies are returned for aml"
    );
    cmp_deeply(
        BOM::Config::Compliance->get_jurisdiction_risk_rating('mt5'),
        {
            labuan => {
                standard   => [],
                high       => bag(qw/e f/),
                restricted => ["g"]
            },
            bvi => {
                standard   => [],
                high       => [],
                restricted => []
            },
            revision => $mocked_global_revision
        },
        "Correct landing companies are returned for mt5"
    );
};

subtest 'validate_jurisdiction_risk_rating' => sub {
    my $mocked_global_revision = 1;
    my $compliance_obj         = BOM::Config::Compliance->new();
    my $mock_countries         = Test::MockModule->new(ref $compliance_obj->_countries)->redefine("country_from_code", 1);

    my $mock_landing_company = Test::MockModule->new('LandingCompany');
    $mock_landing_company->redefine(
        risk_settings => sub {
            my $lc = shift;

            return [qw/aml_jurisdiction/] if $lc->short eq 'maltainvest';
            return [qw/mt5_jurisdiction/] if $lc->short =~ qr/labuan bvi/;
            return [];
        });

    my $input_args = {
        svg => {standard => []},
    };
    like exception { $compliance_obj->validate_jurisdiction_risk_rating('aml', %$input_args) },
        qr/Jursdiction risk ratings are not applicable to the landing company svg/, "landing companies should be valid";

    $input_args = {
        maltainvest => {
            standard => ["es"],
            high     => ["de", "be", "es"]
        },
        revision => $mocked_global_revision
    };
    my $expected = "Duplicate country found in maltainvest jurisdiction ratings: <es> appears both in standard and high listings";
    like exception { $compliance_obj->validate_jurisdiction_risk_rating('aml', %$input_args) }, qr/$expected/, "duplicate country";

    $input_args = {
        maltainvest => {
            standard => ["es"],
            high     => ["de", "be", "be"]
        },
        revision => $mocked_global_revision
    };
    $mock_countries->redefine("country_from_code", 0);
    like exception { $compliance_obj->validate_jurisdiction_risk_rating('aml', %$input_args) }, qr/Invalid country code/,
        "Invalid country code is provided";

    $mock_countries->unmock_all();
    $expected = {
        maltainvest => {
            standard   => ["es"],
            high       => ["be", "de"],
            restricted => []
        },
    };
    is_deeply($compliance_obj->validate_jurisdiction_risk_rating('aml', %$input_args), $expected, "Countries are sorted correctly");

};

done_testing;
