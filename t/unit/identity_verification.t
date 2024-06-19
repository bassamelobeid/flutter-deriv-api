use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockModule;

use BOM::Backoffice::IdentityVerification;
use BOM::Config;
use Brands::Countries;
use JSON::MaybeUTF8 qw(encode_json_utf8);

my $brand_countries_obj = Brands::Countries->new();
my $document_types      = {};

for my $country_config (values $brand_countries_obj->get_idv_config->%*) {
    for my $document_type (keys $country_config->{document_types}->%*) {
        my $display_name =
            ($document_type eq 'national_id') ? 'National ID Number' : $country_config->{document_types}->{$document_type}->{display_name};
        $document_types->{$document_type} //= $display_name;
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
                curp
                dni
                nik
                voter_id
                /
        },
        countries => +{map { ($_ => $brand_countries_obj->countries_list->{$_}->{name}) } qw/br gh ke ng ug za zw in ar mx uy cr cl pe vn id bd cn/},
        providers => +{
            map { ($_ => $idv_config->{providers}->{$_}->{display_name}) }
                qw/zaig smile_identity derivative_wealth data_zoo metamap identity_pass ai_prise/
        },
        statuses => +{map { ($_ => $idv_config->{statuses}->{$_}) } qw/pending failed refuted verified/},
        messages => $idv_config->{messages},
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

    $mock->mock(
        '_documents_query',
        sub {
            my ($ids) = @_;

            return [
                map { +{id => $_, file_name => $_ . 'file.png'}; } grep {
                    $_ % 2 == 0;    # even ids will get an url
                } $ids->@*
            ];
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
        {
            loginids        => ['CR1'],
            status_messages => undef,
            photo_id        => undef
        },
        {
            loginids        => ['CR2'],
            status_messages => undef,
            photo_id        => []
        },
        {
            loginids        => ['CR3'],
            status_messages => undef,
            photo_id        => [1, 2, 3, 4, 5],
        },
        {
            loginids        => ['CR4'],
            status_messages => undef,
            photo_id        => [undef],
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
        {
            loginids => [{
                    loginid => 'CR1',
                    url     => re('CR1'),
                }
            ],
            status_messages => [],
            photo_id        => undef,
        },
        {
            loginids => [{
                    loginid => 'CR2',
                    url     => re('CR2'),
                }
            ],
            status_messages => [],
            photo_id        => [],
        },
        {
            loginids => [{
                    loginid => 'CR3',
                    url     => re('CR3'),
                }
            ],
            status_messages => [],
            photo_urls      => bag(re('2file\.png'), re('4file\.png'),),
            photo_id        => [1, 2, 3, 4, 5],
        },
        {
            loginids => [{
                    loginid => 'CR4',
                    url     => re('CR4'),
                }
            ],
            status_messages => [],
            photo_id        => [undef],
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
        {
            loginids        => ['CR1'],
            status_messages => undef,
            photo_id        => undef
        },
        {
            loginids        => ['CR2'],
            status_messages => undef,
            photo_id        => []
        },
        {
            loginids        => ['CR3'],
            status_messages => undef,
            photo_id        => [1, 2, 3, 4, 5],
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
        {
            loginids        => 'CR1',
            status_messages => '',
            photo_id        => undef,
        },
        {
            loginids        => 'CR2',
            status_messages => '',
            photo_id        => [],
        },
        {
            loginids        => 'CR3',
            status_messages => '',
            photo_id        => [1, 2, 3, 4, 5],
        },
        ],
        'Expected CSV data';

    cmp_deeply BOM::Backoffice::IdentityVerification::get_dashboard(loginid => 'vr90000'), [], 'Empty dashboard for virtual account';

    $mock->unmock_all;
};

done_testing;
