use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;
use List::Util qw(first);
use JSON::MaybeUTF8 qw(encode_json_utf8);

use BOM::Config::Compliance;
use BOM::Config::Runtime;

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

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
        high     => ['in']);
    like exception {
        $compliance_config->validate_jurisdiction_risk_rating(%data)
    }, qr/App config revision is missing/, 'revision is required';

    $data{revision} = 1;
    like exception {
        $compliance_config->validate_jurisdiction_risk_rating(%data)
    }, qr'Duplicate country found: <in> appears both in standard and high risk listings', 'Correct error for duplicate country';

    $data{high} = ['es', 'xyz'];
    like exception {
        $compliance_config->validate_jurisdiction_risk_rating(%data)
    }, qr"Invalid country code <xyz> in high risk listing", 'Correct error for invalid country code';

    $data{high} = ['es', 'at', 'es'];
    cmp_deeply $compliance_config->validate_jurisdiction_risk_rating(%data),
        {
        standard => [qw/af in/],
        high     => ['at', 'es'],
        revision => 1
        },
        'jurisdiction risk listing is correctly returned with unique, sorted country lists';

    my $empty_result = {
        standard => [],
        high     => [],
        revision => 1,
    };
    cmp_deeply $compliance_config->validate_jurisdiction_risk_rating(revision => 1), $empty_result, 'Jursidiction risk validated with empty data';
};

done_testing;
