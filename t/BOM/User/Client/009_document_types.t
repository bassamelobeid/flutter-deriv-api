use strict;
use warnings;

use Test::More;
use Test::Deep qw{!all};
use Test::MockModule;
use Scalar::Util qw/looks_like_number/;
use BOM::User::Client;
use BOM::Test::Helper::Client qw( create_client );
use List::Util qw/all uniq/;
use Array::Utils qw(intersect array_minus unique);

my $categories = [{
        category             => 'POI',
        expiration_strategy  => 'max',
        side_required        => 1,
        document_id_required => 1,
        documents_uploaded   => 'proof_of_identity',
        preferred            => [
            qw/tax_photo_id pan_card nimc_slip passport driving_licence voter_card national_identity_card student_card poi_others proofid driverslicense/
        ],
        date_expiration =>
            [qw/tax_photo_id nimc_slip passport driving_licence voter_card national_identity_card student_card driverslicense proofid/],
        date_issuance  => [],
        date_none      => [qw/birth_certificate pan_card poi_others vf_face_id photo live_photo selfie_with_id/],
        deprecated     => [qw/driverslicense proofid vf_face_id photo live_photo selfie_with_id selfie_with_id/],
        maybe_lifetime => [qw/tax_photo_id nimc_slip passport driving_licence voter_card national_identity_card student_card proofid driverslicense/],
        two_sided      => [qw/poi_others passport driving_licence voter_card national_identity_card student_card nimc_slip pan_card tax_photo_id/],
        photo          => [qw/birth_certificate selfie_with_id/],
        numberless     => [qw/birth_certificate/],
    },
    {
        category             => 'POA',
        expiration_strategy  => 'min',
        side_required        => 0,
        document_id_required => 0,
        documents_uploaded   => 'proof_of_address',
        date_expiration      => [],
        preferred            => [
            qw/utility_bill bank_statement tax_receipt insurance_bill phone_bill poa_others proofaddress payslip bankstatement cardstatement vf_poa/],
        date_issuance =>
            [qw/vf_poa utility_bill bank_statement tax_receipt insurance_bill phone_bill proofaddress payslip bankstatement cardstatement/],
        date_none      => [qw/poa_others/],
        deprecated     => [qw/vf_poa proofaddress payslip bankstatement cardstatement/],
        maybe_lifetime => [],
        two_sided      => [qw/utility_bill bank_statement tax_receipt insurance_bill phone_bill poa_others/],
        photo          => [],
        numberless     => [],
    },
    {
        category             => 'EDD',
        expiration_strategy  => 'min',
        side_required        => 0,
        document_id_required => 0,
        documents_uploaded   => 'other',
        deprecated           => [],
        date_expiration      => [],
        preferred            => [qw/tax_return employment_contract edd_others/],
        date_issuance        => [qw/tax_return employment_contract payslip/],
        date_none            => [qw/edd_others/],
        maybe_lifetime       => [],
        two_sided            => [qw/tax_return employment_contract payslip edd_others/],
        photo                => [],
        numberless           => [],
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
    },
    {
        category             => 'Business documents',
        expiration_strategy  => 'min',
        side_required        => 0,
        document_id_required => 0,
        documents_uploaded   => 'other',
        deprecated           => [],
        date_expiration      => [],
        preferred            => [qw/coi business_poa article_of_association memorandum authorisation_letter declarations business_documents_others/],
        date_issuance        => [qw/coi business_poa article_of_association memorandum authorisation_letter declarations/],
        date_none            => [qw/business_documents_others/],
        maybe_lifetime       => [],
        two_sided            => [qw/coi business_poa article_of_association memorandum authorisation_letter declarations business_documents_others/],
        photo                => [],
        numberless           => [],
    },
    {
        category             => 'Others',
        expiration_strategy  => 'min',
        side_required        => 0,
        document_id_required => 0,
        documents_uploaded   => 'other',
        deprecated           => [],
        date_expiration      => [],
        preferred            => [qw/ip_mismatch_confirmation power_of_attorney code_of_conduct others/],
        date_issuance        => [qw/ip_mismatch_confirmation power_of_attorney code_of_conduct/],
        date_none            => [qw/others/],
        maybe_lifetime       => [],
        two_sided            => [qw/ip_mismatch_confirmation power_of_attorney code_of_conduct others/],
        photo                => [],
        numberless           => [],
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
        $category,  $deprecated,          $documents_uploaded, $date_expiration, $date_issuance,
        $date_none, $expiration_strategy, $preferred,          $maybe_lifetime,  $two_sided,
        $photo,     $numberless,          $side_required,      $document_id_required
        )
        = @{$_}{
        qw/category deprecated documents_uploaded date_expiration date_issuance date_none expiration_strategy preferred maybe_lifetime two_sided photo numberless side_required document_id_required/
        };

    subtest $category => sub {
        ok defined $doctypes{$category}->{types}, "$category has types";
        is ref($doctypes{$category}->{types}), 'HASH', "$category types is a hashref";
        ok defined $doctypes{$category}->{priority},    "$category has a priority";
        ok defined $doctypes{$category}->{description}, "$category has a description";
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
                cmp_bag $sides, [], "$doctype is sideless" if !$two_sided->{$doctype} && !$photo->{$doctype};
            }
        };

        # For each type of document we will mock a documents_uploaded call and check whether the
        # breakdown reported matches our expected `documents_uploaded`

        subtest 'Documents uploaded' => sub {
            for my $doctype (keys $doctypes{$category}->{types}->%*) {
                $document_type = $doctype;

                my $breakdown = $client->documents->uploaded();

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
            payslip
            bankstatement
            cardstatement
            vf_poa
            /
    ];

    cmp_deeply $client->documents->poa_types, set($expected->@*), 'The expected POA types list is looking good';
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
};

subtest 'Preferred types' => sub {
    my $expected = [
        qw/
            passport driving_licence voter_card national_identity_card student_card poi_others proofid driverslicense
            utility_bill bank_statement tax_receipt insurance_bill phone_bill poa_others proofaddress payslip bankstatement cardstatement vf_poa
            tax_return employment_contract edd_others
            selfie video_verification doc_verification
            coi business_poa article_of_association memorandum authorisation_letter declarations business_documents_others
            power_of_attorney code_of_conduct others
            amlglobalcheck nimc_slip
            tax_photo_id pan_card ip_mismatch_confirmation
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
            poa_others
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

done_testing();
