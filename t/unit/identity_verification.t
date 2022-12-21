use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockModule;

use BOM::Backoffice::IdentityVerification;
use Locale::Country;
use BOM::Config;
use Brands::Countries;
use JSON::MaybeUTF8 qw(encode_json_utf8);

my $brand_countries_obj = Brands::Countries->new();
my $document_types      = {};

for my $country_config (values $brand_countries_obj->get_idv_config->%*) {
    for my $document_type (keys $country_config->{document_types}->%*) {
        $document_types->{$document_type} //= $country_config->{document_types}->{$document_type}->{display_name};
    }
}

subtest 'Get Filters data' => sub {
    my $filter_data = BOM::Backoffice::IdentityVerification::get_filter_data;
    my $idv_config  = BOM::Config::identity_verification();
    cmp_deeply $filter_data, +{
        document_types => +{
            map { ($_ => $document_types->{$_}) }
                qw/
                alien_card
                cpf
                drivers_license
                national_id
                national_id_no_photo
                nin_slip
                passport
                ssnit
                aadhaar
                epic
                pan
                /
        },
        countries => +{map { ($_ => Locale::Country::code2country($_)) } qw/br gh ke ng ug za zw in/},
        providers => +{map { ($_ => $idv_config->{providers}->{$_}->{display_name}) } qw/zaig smile_identity derivative_wealth data_zoo/},
        statuses  => +{map { ($_ => $idv_config->{statuses}->{$_}) } qw/pending failed refuted verified/},
        messages  => $idv_config->{messages},
        },
        'Expected data for IDV dashboard filters';
};

subtest 'Get Dashboard data' => sub {
    my $data = [];

    my $mock = Test::MockModule->new('BOM::Backoffice::IdentityVerification');

    $mock->mock(
        '_query',
        sub {
            return $data;
        });

    $data = [{
            loginids        => ['CR9000', 'VR9000', 'CR90001'],
            status_messages => encode_json_utf8(['TEST', 'FAILURE']),
        },
        {
            loginids        => ['MLT90000', 'VRW9000', 'MF9000'],
            status_messages => encode_json_utf8(['NAME_MISMATCH']),
        },
        {
            loginids        => ['CR1234'],
            status_messages => undef,
        },
    ];

    cmp_deeply BOM::Backoffice::IdentityVerification::get_dashboard(),
        [{
            loginids => [{
                    loginid => 'CR9000',
                    url     => re('CR9000'),
                },
                {
                    loginid => 'CR90001',
                    url     => re('CR90001'),
                }
            ],
            status_messages => ['TEST', 'FAILURE']
        },
        {
            loginids => [{
                    loginid => 'MLT90000',
                    url     => re('MLT90000'),
                },
                {
                    loginid => 'MF9000',
                    url     => re('MF9000'),
                }
            ],
            status_messages => ['NAME_MISMATCH']
        },
        {
            loginids => [{
                    loginid => 'CR1234',
                    url     => re('CR1234'),
                }
            ],
            status_messages => []
        },
        ],
        'Expected dashboard data';

    $data = [{
            loginids        => ['CR9000', 'VR9000', 'CR90001'],
            status_messages => encode_json_utf8(['TEST', 'FAILURE']),
        },
        {
            loginids        => ['MLT90000', 'VRW9000', 'MF9000'],
            status_messages => encode_json_utf8(['NAME_MISMATCH']),
        },
        {
            loginids        => ['CR1234'],
            status_messages => undef,
        },
    ];

    cmp_deeply BOM::Backoffice::IdentityVerification::get_dashboard(csv => 1),
        [{
            loginids        => 'CR9000|CR90001',
            status_messages => 'TEST|FAILURE',
        },
        {
            loginids        => 'MLT90000|MF9000',
            status_messages => 'NAME_MISMATCH',
        },
        {
            loginids        => 'CR1234',
            status_messages => '',
        },
        ],
        'Expected CSV data';

    cmp_deeply BOM::Backoffice::IdentityVerification::get_dashboard(loginid => 'vr90000'), [], 'Empty dashboard for virtual account';

    $mock->unmock_all;
};

done_testing;
