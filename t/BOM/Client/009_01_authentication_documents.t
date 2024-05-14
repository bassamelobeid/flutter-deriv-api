use strict;
use warnings;

use Test::More;
use Test::Deep qw{!all};
use Test::MockModule;
use Scalar::Util qw/looks_like_number/;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client );
use List::Util                                 qw/all uniq/;
use Array::Utils                               qw(intersect array_minus unique);
use BOM::User::Client::AuthenticationDocuments::Config;

my $categories = [{
        category             => 'POI',
        expiration_strategy  => 'max',
        side_required        => 1,
        document_id_required => 1,
        documents_uploaded   => 'proof_of_identity',
        preferred            => [
            qw/tax_photo_id pan_card nimc_slip passport driving_licence voter_card national_identity_card identification_number_document service_id_card student_card poi_others proofid driverslicense selfie_with_id/
        ],
        date_expiration => [
            qw/tax_photo_id nimc_slip passport driving_licence voter_card national_identity_card identification_number_document service_id_card student_card driverslicense proofid/
        ],
        date_issuance  => [],
        date_none      => [qw/birth_certificate pan_card poi_others vf_face_id photo live_photo selfie_with_id/],
        deprecated     => [qw/driverslicense proofid vf_face_id photo live_photo selfie_with_id selfie_with_id/],
        maybe_lifetime => [
            qw/tax_photo_id nimc_slip passport driving_licence voter_card national_identity_card identification_number_document service_id_card student_card proofid driverslicense/
        ],
        two_sided => [
            qw/poi_others passport driving_licence voter_card national_identity_card identification_number_document service_id_card student_card nimc_slip pan_card tax_photo_id/
        ],
        photo      => [qw/birth_certificate selfie_with_id/],
        numberless => [qw/birth_certificate/],
        onfido     => [
            qw/passport driving_licence national_identity_card identification_number_document service_id_card proofid vf_face_id selfie_with_id driverslicense/
        ],
    },
    {
        category             => 'POA',
        expiration_strategy  => 'min',
        side_required        => 0,
        document_id_required => 0,
        documents_uploaded   => 'proof_of_address',
        date_expiration      => [],
        preferred            =>
            [qw/utility_bill bank_statement tax_receipt insurance_bill phone_bill poa_others proofaddress bankstatement cardstatement vf_poa/],
        date_issuance =>
            [qw/vf_poa utility_bill bank_statement tax_receipt insurance_bill phone_bill proofaddress bankstatement cardstatement poa_others/],
        date_none      => [],
        deprecated     => [qw/vf_poa proofaddress bankstatement cardstatement/],
        maybe_lifetime => [],
        two_sided      => [qw/utility_bill bank_statement tax_receipt insurance_bill phone_bill poa_others/],
        photo          => [],
        numberless     => [],
        onfido         => [],
    },
    {
        category             => 'EDD',
        expiration_strategy  => 'min',
        side_required        => 0,
        document_id_required => 0,
        documents_uploaded   => 'proof_of_income',
        deprecated           => [],
        date_expiration      => [],
        preferred            => [qw/tax_return employment_contract payslip brokerage_statement edd_others/],
        date_issuance        => [qw/tax_return employment_contract payslip brokerage_statement/],
        date_none            => [qw/edd_others/],
        maybe_lifetime       => [],
        two_sided            => [qw/tax_return employment_contract payslip brokerage_statement edd_others/],
        photo                => [],
        numberless           => [],
        onfido               => [],
    },
    {
        category             => 'Verification - ID',
        expiration_strategy  => 'min',
        side_required        => 0,
        document_id_required => 0,
        documents_uploaded   => 'other',
        deprecated           => [],
        date_expiration      => [],
        preferred            => [qw/selfie video_verification doc_verification/],
        date_issuance        => [qw/video_verification doc_verification/],
        date_none            => [qw/selfie/],
        maybe_lifetime       => [],
        two_sided            => [qw/doc_verification/],
        photo                => [qw/selfie/],
        numberless           => [],
        onfido               => [],
    },
    {
        category             => 'Business documents',
        expiration_strategy  => 'min',
        side_required        => 0,
        document_id_required => 0,
        documents_uploaded   => 'proof_of_income',
        deprecated           => [],
        date_expiration      => [],
        preferred            => [qw/coi business_poa article_of_association memorandum authorisation_letter declarations business_documents_others/],
        date_issuance        => [qw/coi business_poa article_of_association memorandum authorisation_letter declarations/],
        date_none            => [qw/business_documents_others/],
        maybe_lifetime       => [],
        two_sided            => [qw/coi business_poa article_of_association memorandum authorisation_letter declarations business_documents_others/],
        photo                => [],
        numberless           => [],
        onfido               => [],
    },
    {
        category             => 'Others',
        expiration_strategy  => 'min',
        side_required        => 0,
        document_id_required => 0,
        documents_uploaded   => 'other',
        deprecated           => [],
        date_expiration      => [],
        preferred            => [qw/ip_mismatch_confirmation power_of_attorney code_of_conduct others affiliate_reputation_check/],
        date_issuance        => [qw/ip_mismatch_confirmation power_of_attorney code_of_conduct affiliate_reputation_check/],
        date_none            => [qw/others/],
        maybe_lifetime       => [],
        two_sided            => [qw/ip_mismatch_confirmation power_of_attorney code_of_conduct others affiliate_reputation_check/],
        photo                => [],
        numberless           => [],
        onfido               => [],
    },
    {
        category             => 'AML Global Check',
        documents_uploaded   => 'other',
        side_required        => 0,
        document_id_required => 0,
        expiration_strategy  => 'min',
        deprecated           => [],
        date_expiration      => [],
        preferred            => [qw/amlglobalcheck/],
        date_issuance        => [qw/amlglobalcheck/],
        date_none            => [],
        maybe_lifetime       => [],
        two_sided            => [qw/amlglobalcheck/],
        photo                => [],
        numberless           => [],
        onfido               => [],
    },
];

my $defined_sides = {
    back  => 'Back Side',
    front => 'Front Side',
    photo => 'Photo',
};

my $client      = create_client('CR');
my $client_mock = Test::MockModule->new(ref($client));
my $user_mock   = Test::MockModule->new('BOM::User');
my %doctypes    = $client->documents->categories->%*;

my $document_type;
my $expiration_date;

$user_mock->mock(
    'clients',
    sub {
        return ($client);
    });

$client_mock->mock(
    'user',
    sub {
        return bless {}, 'BOM::User';
    });

$client_mock->mock(
    'client_authentication_document',
    sub {
        return (
            bless {
                status          => 'verified',
                document_type   => $document_type,
                file_name       => 'something.png',
                expiration_date => Date::Utility->new()->minus_time_interval('1d'),
                format          => 'png',
                document_id     => 'DOX',
            },
            'BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument'
        );
    });

my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');

$documents_mock->mock(
    'uploaded',
    sub {
        my ($self) = @_;
        $self->_clear_uploaded;
        return $documents_mock->original('uploaded')->(@_);
    });

my @maybe_lifetime_all = $client->documents->maybe_lifetime_types->@*;
my $sided_types_all    = $client->documents->sided_types;

for ($categories->@*) {
    my (
        $category,  $deprecated,          $documents_uploaded, $date_expiration,      $date_issuance,
        $date_none, $expiration_strategy, $preferred,          $maybe_lifetime,       $two_sided,
        $photo,     $numberless,          $side_required,      $document_id_required, $onfido
        )
        = @{$_}{
        qw/category deprecated documents_uploaded date_expiration date_issuance date_none expiration_strategy preferred maybe_lifetime two_sided photo numberless side_required document_id_required onfido/
        };

    subtest $category => sub {
        ok defined $doctypes{$category}->{types}, "$category has types";
        is ref($doctypes{$category}->{types}), 'HASH', "$category types is a hashref";
        ok defined $doctypes{$category}->{priority},            "$category has a priority";
        ok defined $doctypes{$category}->{description},         "$category has a description";
        ok looks_like_number($doctypes{$category}->{priority}), "$category priority looks like a number";
        is $doctypes{$category}->{expiration_strategy}, $expiration_strategy, "$category has the $expiration_strategy expiration strategy defined"
            if defined $expiration_strategy;
        ok $side_required == $doctypes{$category}->{side_required},               "$category side required = $side_required";
        ok $document_id_required == $doctypes{$category}->{document_id_required}, "$category doc id required = $document_id_required";

        my @category_types = keys $doctypes{$category}->{types}->%*;
        my @sided_types    = unique(@$two_sided, @$photo);

        cmp_set [map { ($doctypes{$category}->{types}->{$_}->{preferred} // 0) ? $_ : () } @category_types], $preferred,
            'Preferred types are looking good';
        cmp_set [map { ($doctypes{$category}->{types}->{$_}->{deprecated} // 0) ? $_ : () } @category_types], $deprecated,
            'Deprecated types are looking good';
        cmp_set [map { $doctypes{$category}->{types}->{$_}->{date} eq 'expiration' ? $_ : () } @category_types],
            $date_expiration, 'Types with an expiration date are looking good';
        cmp_set [map { $doctypes{$category}->{types}->{$_}->{date} eq 'issuance' ? $_ : () } @category_types],
            $date_issuance, 'Types with an issuance date are looking good';
        cmp_set [map { $doctypes{$category}->{types}->{$_}->{date} eq 'none' ? $_ : () } @category_types],
            $date_none, 'Types without a date are looking good';
        cmp_set [map { $doctypes{$category}->{types}->{$_}->{sides}->{front} && $doctypes{$category}->{types}->{$_}->{sides}->{back} ? $_ : () }
                @category_types],
            $two_sided, 'Two sided types are looking good';
        cmp_set [map { $doctypes{$category}->{types}->{$_}->{sides}->{photo} ? $_ : () } @category_types],
            $photo, 'Photo sided types are looking good';
        cmp_set [map { scalar keys $doctypes{$category}->{types}->{$_}->{sides}->%* == 0 ? $_ : () } @category_types],
            [array_minus(@category_types, @sided_types)], 'Sideless types are looking good';
        cmp_set [map { $doctypes{$category}->{types}->{$_}->{numberless} ? $_ : () } @category_types], $numberless,
            'Numberless types are looking good';
        cmp_set [intersect(@maybe_lifetime_all, @category_types)], $maybe_lifetime, 'Maybe lifetime types are looking good for this category';
        cmp_set [map { $doctypes{$category}->{types}->{$_}->{providers}->{onfido} ? $_ : () } @category_types], $onfido,
            'Onfido types are looking good';

        for my $non_deprecated (map { ($doctypes{$category}->{types}->{$_}->{deprecated} // 0) ? () : $_ } @category_types) {
            ok defined $doctypes{$category}->{types}->{$non_deprecated}->{description}, "$non_deprecated is not deprecated and has a description";
            ok defined $doctypes{$category}->{types}->{$non_deprecated}->{priority},    "$non_deprecated is not deprecated and has a priority";
        }

        my $two_sided = +{map { $_ => 1 } $two_sided->@*};
        my $photo     = +{map { $_ => 1 } $photo->@*};

        subtest 'Document Sides' => sub {
            for my $doctype (keys $doctypes{$category}->{types}->%*) {
                my $sides = [keys $doctypes{$category}->{types}->{$doctype}->{sides}->%*];
                cmp_bag $sides, [qw/front back/], "$doctype is a two sided doctype" if $two_sided->{$doctype};
                cmp_bag $sides, [qw/photo/],      "$doctype is a photo doctype"     if $photo->{$doctype};
                cmp_bag $sides, [],               "$doctype is sideless"            if !$two_sided->{$doctype} && !$photo->{$doctype};
            }
        };

        # For each type of document we will mock a documents_uploaded call and check whether the
        # breakdown reported matches our expected `documents_uploaded`

        subtest 'Documents uploaded' => sub {
            for my $doctype (keys $doctypes{$category}->{types}->%*) {
                $document_type = $doctype;

                my $breakdown = $client->documents->uploaded();

                # check this
                # Note `payslip` used to be a proof_of_address doctype, for backwards compatibility we
                # still use it for POA checkups and it should be tested in that category

                next if $doctype eq 'payslip' and $category ne 'POA';

                # Only `preferred` documents are validated
                # Note we may have `deprecated` types but still `preferred` for legacy purposes.
                next unless $doctypes{$category}->{types}->{$doctype}->{preferred};

                ok defined $breakdown->{$documents_uploaded}, "Documents uploaded reports a '$documents_uploaded' section for $doctype";

                # Note our documents are all expired on purpose on the mock, but only the document types with `expiration`
                # should report it
                my $expires = ($doctypes{$category}->{types}->{$doctype}->{date} // '') eq 'expiration';

                ok $breakdown->{$documents_uploaded}{is_expired}, "$category should report a expired document for $doctype" if $expires;
                ok !defined $breakdown->{$documents_uploaded}{is_expired}, "$category should not report a expired document for $doctype"
                    unless $expires;
            }
        }
    }
}

subtest 'POA document types' => sub {
    my $expected = [
        qw/
            utility_bill
            bank_statement
            tax_receipt
            insurance_bill
            phone_bill
            poa_others
            proofaddress
            bankstatement
            cardstatement
            vf_poa
            /
    ];

    cmp_deeply $client->documents->poa_types, set($expected->@*), 'The expected POA types list is looking good';

    cmp_deeply BOM::User::Client::AuthenticationDocuments::Config::poa_types(), set($expected->@*), 'The expected POA types list is looking good';
};

subtest 'POI document types' => sub {
    my $expected = [
        qw/
            tax_photo_id
            pan_card
            nimc_slip
            birth_certificate
            passport
            driving_licence
            voter_card
            national_identity_card
            identification_number_document
            service_id_card
            student_card
            poi_others
            proofid
            vf_face_id
            photo
            live_photo
            selfie_with_id
            driverslicense
            /
    ];

    cmp_deeply $client->documents->poi_types, set($expected->@*), 'The expected POI types list is looking good';

    cmp_deeply BOM::User::Client::AuthenticationDocuments::Config::poi_types(), set($expected->@*), 'The expected POI types list is looking good';
};

subtest 'Preferred types' => sub {
    my $expected = [
        qw/
            passport driving_licence voter_card national_identity_card identification_number_document service_id_card student_card poi_others proofid driverslicense
            utility_bill bank_statement tax_receipt insurance_bill phone_bill poa_others proofaddress payslip bankstatement cardstatement vf_poa
            tax_return employment_contract edd_others brokerage_statement
            selfie video_verification doc_verification
            coi business_poa article_of_association memorandum authorisation_letter declarations business_documents_others
            power_of_attorney code_of_conduct others
            amlglobalcheck nimc_slip
            tax_photo_id pan_card ip_mismatch_confirmation affiliate_reputation_check selfie_with_id
            /
    ];

    cmp_deeply $client->documents->preferred_types, set($expected->@*), 'The expected preferred types list is looking good';
};

subtest 'Issuance document types' => sub {
    my $expected = [
        qw/
            utility_bill
            bank_statement
            tax_receipt
            insurance_bill
            phone_bill
            proofaddress
            payslip
            bankstatement
            cardstatement
            vf_poa
            tax_return
            payslip
            video_verification
            brokerage_statement
            doc_verification
            coi
            business_poa
            article_of_association
            memorandum
            authorisation_letter
            declarations
            power_of_attorney
            code_of_conduct
            employment_contract
            amlglobalcheck
            ip_mismatch_confirmation
            affiliate_reputation_check
            poa_others
            /
    ];

    cmp_deeply $client->documents->issuance_types, set($expected->@*), 'The expected issuance types list is looking good';
};

subtest 'Dateless document types' => sub {
    my $expected = [
        qw/
            pan_card
            poi_others
            vf_face_id
            photo
            live_photo
            selfie_with_id
            edd_others
            poi_others
            business_documents_others
            others
            selfie
            birth_certificate
            /
    ];

    cmp_deeply $client->documents->dateless_types, set($expected->@*), 'The expected date less types list is looking good';
};

subtest 'Expirable document types' => sub {
    my $expected = [
        qw/
            passport
            driving_licence
            student_card
            voter_card
            national_identity_card
            identification_number_document
            service_id_card
            proofid
            driverslicense
            nimc_slip
            tax_photo_id
            /
    ];

    cmp_deeply $client->documents->expirable_types, set($expected->@*), 'The expected expirable types list is looking good';
};

subtest 'Sides' => sub {
    cmp_deeply $client->documents->sides, $defined_sides, 'Expected sides';
};

subtest 'Onfido mapping' => sub {
    my $mappings = {
        passport                       => 'passport',
        driving_licence                => 'driving_licence',
        national_identity_card         => 'national_identity_card',
        identification_number_document => 'identification_number_document',
        service_id_card                => 'service_id_card',
        proofid                        => 'national_identity_card',
        vf_face_id                     => 'live_photo',
        selfie_with_id                 => 'live_photo',
        driverslicense                 => 'driving_licence',
    };

    cmp_deeply $client->documents->provider_types->{onfido}, $mappings, 'Expected Onfido types mapping';
};

subtest 'poa_address_mismatch with redis replicated' => sub {
    poa_address_mismatch_test(BOM::Config::Redis::redis_replicated_write());
};

subtest 'poa_address_mismatch with redis events' => sub {
    poa_address_mismatch_test(BOM::Config::Redis::redis_events_write());
};

subtest 'poa_address_mismatch fallback to replicated' => sub {
    my $redis_mock  = Test::MockModule->new('RedisDB');
    my $get_flipper = -1;

    # the first get is from redis events
    $redis_mock->mock(
        'get',
        sub {
            $get_flipper = $get_flipper * -1;

            return undef if $get_flipper == 1;

            return $redis_mock->original('get')->(@_);
        });

    poa_address_mismatch_test(BOM::Config::Redis::redis_replicated_write());

    $redis_mock->unmock_all();
};

sub poa_address_mismatch_test {
    my $redis    = shift;
    my $expected = 'Main St. 123';
    my $key      = 'POA_ADDRESS_MISMATCH::' . $client->binary_user_id;

    my $params_full = {
        expected_address => 'Main St. 123',
        staff            => 'User123',
        reason           => 'Client POA address mismatch',
    };

    $client->status->clear_poa_address_mismatch();
    is $client->documents->poa_address_mismatch($params_full), $expected, 'Expected to set redis with expected address';
    ok $redis->ttl($key), 'TTL Set';
    my $status_check     = $client->status->_get('poa_address_mismatch');
    my $current_expected = $status_check->{status_code};
    is $current_expected, 'poa_address_mismatch', 'Client status was set correctly';

    my $params_reason = {
        expected_address => 'Main St. 123',
        reason           => 'Client POA address mismatch',
    };

    $client->status->clear_poa_address_mismatch();
    is $client->documents->poa_address_mismatch($params_reason), $expected, 'Expected to set redis with expected address';
    ok $redis->ttl($key), 'TTL Set';
    $status_check     = $client->status->_get('poa_address_mismatch');
    $current_expected = $status_check->{status_code};
    is $current_expected, 'poa_address_mismatch', 'Client status was set correctly';

    my $params_staff = {
        expected_address => 'Main St. 123',
        staff            => 'User123',
    };

    $client->status->clear_poa_address_mismatch();
    is $client->documents->poa_address_mismatch($params_staff), $expected, 'Expected to set redis with expected address';
    ok $redis->ttl($key), 'TTL Set';
    $status_check     = $client->status->_get('poa_address_mismatch');
    $current_expected = $status_check->{status_code};
    is $current_expected, 'poa_address_mismatch', 'Client status was set correctly';

    # Call to getter (no params), status should be undef
    $client->status->clear_poa_address_mismatch();
    is $client->documents->poa_address_mismatch(), $expected, 'Expected to get redis with expected address';
    $status_check     = $client->status->_get('poa_address_mismatch');
    $current_expected = $status_check->{status_code};
    is $current_expected, undef, 'Client status is undef';

}

subtest 'is_poa_address_fixed' => sub {
    is_poa_address_fixed_test();
};

subtest 'is_poa_address_fixed fallback to replicated' => sub {
    my $redis_mock  = Test::MockModule->new('RedisDB');
    my $get_flipper = -1;

    # the first get is from redis events
    $redis_mock->mock(
        'get',
        sub {
            $get_flipper = $get_flipper * -1;

            print $get_flipper;

            return undef if $get_flipper == 1;

            return $redis_mock->original('get')->(@_);
        });

    is_poa_address_fixed_test();

    $redis_mock->unmock_all();
};

sub is_poa_address_fixed_test {
    my @tests = ({
            title            => 'Identical Match',
            expected_address => 'Main St. 123',
            staff            => 'User123',
            reason           => 'Client POA address mismatch',
            address_1        => 'Main St. 123',
            address_2        => '123',
            expected         => 1,
        },
        {
            title            => 'Empty Address 2',
            expected_address => 'Main St. 123',
            staff            => 'User123',
            reason           => 'Client POA address mismatch',
            address_1        => 'Main St. 123',
            address_2        => '',
            expected         => 1,
        },
        {
            title            => 'Complete Different Addresses',
            expected_address => 'Elm St. 456',
            staff            => 'User123',
            reason           => 'Client POA address mismatch',
            address_1        => 'Main St.',
            address_2        => '123',
            expected         => 0,
        },
        {
            title            => 'High enough percentage',
            expected_address => 'This is test address to check percentage',
            staff            => 'User123',
            reason           => 'Client POA address mismatch',
            address_1        => 'This is address to check percentage',
            address_2        => '',
            expected         => 1,
        },
    );

    foreach my $test (@tests) {
        subtest $test->{title} => sub {
            my $params = {
                expected_address => $test->{expected_address},
                staff            => $test->{staff},
                reason           => $test->{reason},
            };

            $client->status->clear_poa_address_mismatch();
            $client->documents->poa_address_mismatch($params);
            $client->address_1($test->{address_1});
            $client->address_2($test->{address_2});

            is $client->documents->is_poa_address_fixed(), $test->{expected}, 'Address should match for this test - ' . $test->{title};
        };
    }
}

sub upload_test_document {
    my ($document_args, $client) = @_;

    my $upload_info = $client->db->dbic->run(
        ping => sub {
            $_->selectrow_hashref(
                'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::betonmarkets.client_document_origin)', undef,
                $client->loginid, $document_args->{document_type},
                $document_args->{document_format}, $document_args->{expiration_date} || undef,
                $document_args->{document_id} || '', $document_args->{expected_checksum},
                '', $document_args->{page_type} || '', undef, 0, 'legacy'
            );
        });

    $client->db->dbic->run(
        ping => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $upload_info->{file_id});
        });

    return $upload_info;
}

subtest 'poa_address_fix' => sub {
    $client_mock->unmock('client_authentication_document');
    $documents_mock->unmock_all;

    my $redis = BOM::Config::Redis::redis_events();
    my $key   = 'POA_ADDRESS_MISMATCH::' . $client->binary_user_id;
    my @tests = ({
            title                => 'Identical Match - Not age verified',
            expected_address     => 'Main St. 123',
            staff                => 'User123',
            reason               => 'Client POA address mismatch',
            address_1            => 'Main St. 123',
            address_2            => '123',
            expected             => 1,
            age_verification     => 0,
            poa_address_mismatch => 1,
            checksum             => 'test123',
        },
        {
            title                => 'Identical Match - Age verified',
            expected_address     => 'Main St. 123',
            staff                => 'User123',
            reason               => 'Client POA address mismatch',
            address_1            => 'Main St. 123',
            address_2            => '123',
            expected             => 1,
            age_verification     => 1,
            poa_address_mismatch => 1,
            checksum             => 'test234',
        },
        {
            title                => 'Identical Match - Not age verified or mismatch flag',
            expected_address     => 'Main St. 123',
            staff                => 'User123',
            reason               => 'Client POA address mismatch',
            address_1            => 'Main St. 123',
            address_2            => '123',
            expected             => 1,
            age_verification     => 0,
            poa_address_mismatch => 0,
            checksum             => 'test345',
        },

    );
    foreach my $test (@tests) {
        subtest $test->{title} => sub {
            my $params = {
                expected_address => $test->{expected_address},
                staff            => $test->{staff},
                reason           => $test->{reason},
            };

            my $args = {
                document_type     => 'utility_bill',
                document_format   => 'PDF',
                document_id       => undef,
                expiration_date   => undef,
                expected_checksum => $test->{checksum},
                page_type         => undef,
            };

            $client->status->clear_poa_address_mismatch();
            $client->status->clear_address_verified();

            if ($test->{poa_address_mismatch}) {
                $client->documents->poa_address_mismatch($params);
            }
            $client->address_1($test->{address_1});
            $client->address_2($test->{address_2});

            # clear fully_authenticated

            $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'}, $test->{staff});

            if ($test->{age_verification}) {
                $client->status->setnx('age_verification', 'test', 'test');
            } else {
                $client->status->clear_age_verification;
            }

            my $test_doc = upload_test_document($args, $client);
            my ($doc) = $client->find_client_authentication_document(query => [id => $test_doc->{file_id}]);
            $doc->address_mismatch(1);
            $doc->save;

            if ($test->{poa_address_mismatch}) {
                ok $client->find_client_authentication_document(query => [address_mismatch => 1]), 'Document is flagged as address mismatch';
                is $client->documents->is_poa_address_fixed(), $test->{expected}, 'Address should match for this test';
                $client->documents->poa_address_fix;
            } else {
                is !$client->documents->is_poa_address_fixed(), $test->{expected}, 'No address to fix';
                $client->documents->poa_address_mismatch_clear;
            }

            ok !$redis->get($key),                     'Redis key is gone';
            ok !$client->status->poa_address_mismatch, 'Poa address mismatch flag should be off';
            $client = BOM::User::Client->new({loginid => $client->loginid});

            if ($test->{poa_address_mismatch}) {
                ok $client->status->address_verified, 'Address status should be verified';

                my ($doc) = $client->find_client_authentication_document(query => [address_mismatch => 1]);
                ok !$doc,                               'No flag for mismatch document';
                ok $client->documents->is_poa_verified, 'POA is verified';
            } else {
                ok !$client->status->address_verified, 'Address status should not be verified';
                my ($doc) = $client->find_client_authentication_document(query => [address_mismatch => 1]);
                ok $doc,                                 'Document remains in address mismatch';
                ok !$client->documents->is_poa_verified, 'POA is not verified';
            }

            if ($test->{age_verification}) {
                ok $client->fully_authenticated();
            } else {
                ok !$client->fully_authenticated();
            }

            for my $d ($client->find_client_authentication_document()->@*) {
                $d->status('uploaded');
                $d->save;
            }
        };
    }
};

subtest 'clear POA mismatch manually' => sub {
    my $redis  = BOM::Config::Redis::redis_events();
    my $key    = 'POA_ADDRESS_MISMATCH::' . $client->binary_user_id;
    my $params = {
        expected_address => 'supicious address',
        staff            => 'User123',
        reason           => 'Client POA address mismatch',
    };

    $client->status->clear_poa_address_mismatch();
    $client->status->clear_address_verified();

    $client->address_1('Main St. 123');
    $client->address_2('123');
    $client->documents->poa_address_mismatch($params);

    $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'}, $params->{staff});

    $client->status->setnx('age_verification', 'test', 'test');

    is $client->documents->is_poa_address_fixed(), 0, 'Address do not match';

    $client->documents->poa_address_mismatch_clear;

    ok !$redis->get($key),                     'Redis key is gone';
    ok !$client->status->poa_address_mismatch, 'Poa address mismatch flag is off';
    ok !$client->status->address_verified,     'Address status is not verified';
    ok !$client->fully_authenticated(),        'Client is not fully authenticated';
};

subtest 'has verified POA' => sub {
    $client_mock->mock(
        'client_authentication_document',
        sub {
            return (
                bless {
                    status          => 'verified',
                    document_type   => 'utility_bill',
                    file_name       => 'something.png',
                    expiration_date => Date::Utility->new()->minus_time_interval('1d'),
                    format          => 'png',
                    document_id     => 'DOX',
                },
                'BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument'
            );
        });

    $client->documents->_clear_uploaded;
    $client->documents->_clear_is_poa_verified;
    ok $client->documents->is_poa_verified, 'PoA is verified';

    $client_mock->mock(
        'client_authentication_document',
        sub {
            return (
                bless {
                    status          => 'rejected',
                    document_type   => 'utility_bill',
                    file_name       => 'something.png',
                    expiration_date => Date::Utility->new()->minus_time_interval('1d'),
                    format          => 'png',
                    document_id     => 'DOX',
                },
                'BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument'
            );
        });

    $client->documents->_clear_uploaded;
    $client->documents->_clear_is_poa_verified;
    ok !$client->documents->is_poa_verified, 'PoA is not verified';

    $client_mock->mock(
        'client_authentication_document',
        sub {
            return ();
        });

    $client->documents->_clear_uploaded;
    $client->documents->_clear_is_poa_verified;
    ok !$client->documents->is_poa_verified, 'PoA is not verified';

    $client_mock->mock(
        'client_authentication_document',
        sub {
            return (
                bless {
                    status        => 'verified',
                    document_type => 'utility_bill',
                    file_name     => 'something.png',
                    format        => 'png',
                    document_id   => 'DOX',
                    verified_date => Date::Utility->new()->minus_time_interval('1y')->minus_time_interval('1d')->minus_time_interval('1s'),
                },
                'BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument'
            );
        });

    $client->documents->_clear_uploaded;
    $client->documents->_clear_is_poa_verified;
    ok !$client->documents->is_poa_verified, 'PoA is not verified';

};

subtest 'Verified' => sub {
    # No documents uplaoded
    is $client->documents->verified, 0, 'should not be verified, no documents uploaded';

    # Should return 0 if poi document is expired
    my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    my $is_expired;
    my $is_verified;
    $documents_mock->mock(
        'uploaded',
        sub {
            return {
                'proof_of_identity' => {
                    is_expired  => $is_expired,
                    is_verified => $is_verified,
                },

            };
        });
    $is_expired  = 1;
    $is_verified = 0;
    is $client->documents->verified, 0, 'should not be verified, documents expired';
    $client->documents->_clear_uploaded;

    $is_expired  = 0;
    $is_verified = 0;
    is $client->documents->verified, 0, 'should not be verified';
    $client->documents->_clear_uploaded;

    $is_expired  = 0;
    $is_verified = 1;
    is $client->documents->verified, 1, 'should  be verified';
    $client->documents->_clear_uploaded;

};

subtest 'check_words_similarity' => sub {

    my $expected_address = 'Main St. 123';

    my $current_address = 'Main St. 123';

    my $ratio = BOM::User::Client::AuthenticationDocuments::check_words_similarity($current_address, $expected_address);

    is $ratio, 1, 'match is perfect';

    $expected_address = 'Main St. 123';

    $current_address = 'Main St.';

    $ratio = BOM::User::Client::AuthenticationDocuments::check_words_similarity($current_address, $expected_address);

    is $ratio, 0.666666666666667, 'match is 2/3 correct, we would possible not verify this user';

    $expected_address = 'Main St. 123';

    $current_address = 'MAIN St.';

    $ratio = BOM::User::Client::AuthenticationDocuments::check_words_similarity($current_address, $expected_address);

    is $ratio, 0.666666666666667, 'match is 2/3 correct, we would possible not verify this user - case insensitivity';

    $expected_address = 'Main  St. 123';

    $current_address = 'Main St.';

    $ratio = BOM::User::Client::AuthenticationDocuments::check_words_similarity($current_address, $expected_address);

    is $ratio, 0.666666666666667, 'match is 2/3 correct, we would possible not verify this user- extra whitespace';

};

# is upload available test suite

subtest 'is upload available with redis replicated' => sub {
    is_upload_available_test(BOM::Config::Redis::redis_replicated_write(), 'is_available@deriv.com');
};

subtest 'is upload available configuration with redis events' => sub {
    is_upload_available_test(BOM::Config::Redis::redis_events_write(), 'is_available2@deriv.com');
};

subtest 'is upload available fallback to replicated' => sub {
    my $redis_mock  = Test::MockModule->new('RedisDB');
    my $get_flipper = -1;

    # the first get is from redis events
    $redis_mock->mock(
        'get',
        sub {
            $get_flipper = $get_flipper * -1;

            return undef if $get_flipper == 1;

            return $redis_mock->original('get')->(@_);
        });

    is_upload_available_test(BOM::Config::Redis::redis_replicated_write(), 'is_available3@deriv.com');

    $redis_mock->unmock_all();
};

sub is_upload_available_test {
    my $redis = shift;

    my $user_cr = BOM::User->create(
        email    => shift,
        password => 'secret_pwd'
    );

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $user_cr->add_client($client_cr);

    my $client_model = BOM::User::Client->new({loginid => $client_cr->loginid});

    ok $client_model->documents->is_upload_available, 'is available if has attempts left';

    my $key = 'MAX_UPLOADS_KEY::' . $client_cr->binary_user_id;
    $redis->set($key, 21,);

    ok !$client_model->documents->is_upload_available, 'is not available if has no attempts left';
}

done_testing();
