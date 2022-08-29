use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;
use List::Util      qw(first);
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);

use BOM::Config::Compliance;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

subtest 'risk thresholds' => sub {
    my $compliance_config = BOM::Config::Compliance->new;

    subtest 'validate' => sub {
        my %args = ();

        for my $threshold (BOM::Config::Compliance::RISK_THRESHOLDS) {
            $args{CR}->{$threshold->{name}} = 'abcd';
            like exception { $compliance_config->validate_risk_thresholds(%args) },
                qr/Invalid numeric value for CR $threshold->{title}: abcd/,
                "$threshold->{title} should be numeric";

            delete $args{CR}->{$threshold->{name}};
        }

        $args{CR} = {
            yearly_high     => 100,
            yearly_standard => 100
        };
        is exception {
            $compliance_config->validate_risk_thresholds(%args)
        }, undef, 'It succeeds with numerical values';

        $args{CR}->{yearly_high} = 99;
        like exception { $compliance_config->validate_risk_thresholds(%args) },
            qr/Yearly Standard threshold is higher than Yearly High Risk threshold/,
            'high risk threshold cannot be lower than the standard threshold';

        for my $broker (qw/CR MF/) {
            $args{$broker} = {};
            $compliance_config->validate_risk_thresholds(%args);
            cmp_deeply $args{$broker},
                {
                yearly_high     => undef,
                yearly_standard => undef
                },
                "$broker - Undefined values are correctly saved and retrieved (meaning that there are no threasholds)";

            $args{$broker} = {
                yearly_high     => 3.011,
                yearly_standard => 1.000001
            };
            $compliance_config->validate_risk_thresholds(%args);
            cmp_deeply $args{$broker},
                {
                yearly_high     => num(3.01),
                yearly_standard => num(1.00)
                },
                "$broker - Values are rounded to 2 derimal digits";
        }
    };

    subtest 'get_thresholds' => sub {
        like exception { $compliance_config->get_risk_thresholds }, qr/Threshold type is missing/, 'Correct error for missing threshold type';
        like exception { $compliance_config->get_risk_thresholds('dummy') }, qr/Invalid threshold type dummy/,
            'Correct error for invalid threshold type';

        cmp_deeply $compliance_config->get_risk_thresholds('aml'),
            {
            revision => ignore(),
            CR       => {
                yearly_high     => ignore(),
                yearly_standard => ignore()
            },
            MF => {
                yearly_high     => ignore(),
                yearly_standard => ignore()}
            },
            'The defautl AML risk thresholds are correctly retrieved';

        cmp_deeply $compliance_config->get_risk_thresholds('mt5'),
            {
            revision   => ignore(),
            'real/bvi' => {
                yearly_high     => ignore(),
                yearly_standard => ignore()
            },
            'real/labuan' => {
                yearly_high     => ignore(),
                yearly_standard => ignore()
            },
            'real/vanuatu' => {
                yearly_high     => ignore(),
                yearly_standard => ignore()}
            },
            'MT5 risk thresholds are correctly retrieved';

        my $data = {
            CR => {
                yearly_high     => 10000,
                yearly_standard => 5000
            },
            MF => {
                yearly_high     => 5000,
                yearly_standard => 3000
            }};
        $app_config->set({'compliance.aml_risk_thresholds' => encode_json_utf8($data)});
        cmp_deeply $compliance_config->get_risk_thresholds('aml'),
            {
            revision => ignore(),
            %$data,
            },
            'The saved AML risk thresholds are correctly retrieved';
    };
};

subtest 'get jurisdiction risk rating' => sub {
    my $compliance_config = BOM::Config::Compliance->new;
    my $data              = {};
    $app_config->set({'compliance.jurisdiction_risk_rating', encode_json_utf8($data)});

    cmp_deeply $compliance_config->get_jurisdiction_risk_rating(),
        {
        standard => [],
        high     => [],
        revision => ignore()
        },
        'jurisdiction risk config is correct';

    $data->{standard} = ['sn', 'es'];
    $data->{high}     = ['in', 'af', 'de'];
    $app_config->set({'compliance.jurisdiction_risk_rating', encode_json_utf8($data)});

    cmp_deeply $compliance_config->get_jurisdiction_risk_rating(),
        {
        standard => ['es', 'sn'],
        high     => ['af', 'de', 'in'],
        revision => ignore()
        },
        'jursdiction risk config is correct - all countries sorted';

    $data = $data = {
        standard => [],
        high     => []};
    $app_config->set({'compliance.jurisdiction_risk_rating', encode_json_utf8($data)});

};

subtest 'validate jurisdiction risk rating' => sub {
    my $compliance_config = BOM::Config::Compliance->new;

    my %data = (
        standard => ['in', 'af'],
        high     => ['es', 'xyz']);

    like exception {
        $compliance_config->validate_jurisdiction_risk_rating(%data)
    }, qr"Invalid country code <xyz> in high risk listing", 'Correct error for invalid country code';

    $data{high} = ['es', 'at', 'es'];
    cmp_deeply $compliance_config->validate_jurisdiction_risk_rating(%data),
        {
        standard => [qw/af in/],
        high     => ['at', 'es']
        },
        'jurisdiction risk listing is correctly returned with unique, sorted country lists';

    my $empty_result = {
        standard => [],
        high     => []};
    cmp_deeply $compliance_config->validate_jurisdiction_risk_rating(), $empty_result, 'Jursidiction risk validated with empty data';
};

done_testing;
