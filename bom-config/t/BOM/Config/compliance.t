use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockObject;

use BOM::Config::Compliance;
use BOM::Config::Runtime;

use JSON::MaybeUTF8 qw(encode_json_utf8);

subtest 'get_npj_countries_list' => sub {
    my $npj_countries_list = {
        bvi     => ['gi'],
        labuan  => [],
        vanuatu => ['ke'],
    };

    my $instance          = BOM::Config::Runtime->instance;
    my $mocked_instance   = Test::MockObject->new($instance);
    my $mocked_app_config = Test::MockObject->new();

    $mocked_instance->mock('app_config' => sub { return $mocked_app_config });
    $mocked_app_config->mock(
        'get' => sub {
            return encode_json_utf8($npj_countries_list);
        });
    $mocked_app_config->mock('global_revision' => sub { return 1 });

    my $compliance_config = BOM::Config::Compliance->new();
    my $result            = $compliance_config->get_npj_countries_list();
    delete $result->{revision};
    cmp_deeply $npj_countries_list, $result, 'get_npj_countries_list returns expected npj countries list';

    $npj_countries_list = {
        bvi     => ['id', 'my'],
        labuan  => ['id'],
        vanuatu => ['ke'],
    };

    $result = $compliance_config->get_npj_countries_list();
    delete $result->{revision};
    cmp_deeply $npj_countries_list, $result, 'get_npj_countries_list returns expected npj countries list';

    subtest 'is_tin_required' => sub {
        $npj_countries_list = {vanuatu => ['ke']};

        my $compliance_config = BOM::Config::Compliance->new();

        dies_ok { $compliance_config->is_tin_required(), 'no country' } 'is_tin_required requires country as argument';
        dies_ok { $compliance_config->is_tin_required('ke'), 'no landing_company' } 'is_tin_required requires landing_company as argument';

        ok !$compliance_config->is_tin_required('ke', 'vanuatu'),     'tin not required for npj country for the provided landing company';
        ok $compliance_config->is_tin_required('gh',  'vanuatu'),     'tin required for pj country for vanuatu landing company';
        ok $compliance_config->is_tin_required('gh',  'bvi'),         'tin required for pj country for bvi landing company';
        ok $compliance_config->is_tin_required('gh',  'maltainvest'), 'tin required for pj country for bvi landing company';
        ok !$compliance_config->is_tin_required('ke', 'svg'),         'tin not required for pj country for svg landing company';
    };
};

done_testing();
