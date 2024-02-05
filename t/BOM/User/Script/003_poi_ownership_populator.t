use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);

use BOM::User::Script::POIOwnershipPopulator;
use LandingCompany::Registry;

my $mock = Test::MockModule->new('BOM::User::Script::POIOwnershipPopulator');
my $ownable_documents_hit;
$mock->mock(
    'ownable_documents',
    sub {
        $ownable_documents_hit++;
        return $mock->original('ownable_documents')->(@_);
    });
my $apply_ownership_hit;
$mock->mock(
    'apply_ownership',
    sub {
        $apply_ownership_hit++;
        return $mock->original('apply_ownership')->(@_);
    });

my @broker_codes = LandingCompany::Registry->all_real_broker_codes();

subtest 'Empty tables' => sub {
    $ownable_documents_hit = 0;
    $apply_ownership_hit   = 0;

    is BOM::User::Script::POIOwnershipPopulator::run(), undef,                'Script run successfully';
    is $apply_ownership_hit,                            0,                    'no ownership applied';
    is $ownable_documents_hit,                          scalar @broker_codes, 'queried the db once (per broker code)';
};

my $owners;
my $copycats;

subtest 'Ownership is applied' => sub {
    $owners = seed(
        40,
        {
            type    => 'passport',
            country => 'br',
            prefix  => 'thefirstone',
        });

    $copycats = seed(
        40,
        {
            type    => 'passport',
            country => 'br',
            prefix  => 'thefirstone',
        });

    $ownable_documents_hit = 0;
    $apply_ownership_hit   = 0;

    is BOM::User::Script::POIOwnershipPopulator::run(), undef,                'Script run successfully';
    is $apply_ownership_hit,                            scalar @broker_codes, 'ownership applied once (per broker)';
    is $ownable_documents_hit,                          scalar @broker_codes, 'queried the db once (per broker)';

    subtest 'owners' => sub {
        my $i = 0;

        for my $owner ($owners->@*) {
            my $client = $owner->{client};
            $i++;

            ok $client->documents->owned('passport', 'thefirstone' . $i, 'br'), 'Expected owner';
        }
    };

    subtest 'copycats' => sub {
        my $i = 0;

        for my $copycat ($copycats->@*) {
            my $client = $copycat->{client};
            $i++;

            ok !$client->documents->owned('passport', 'thefirstone' . $i, 'br'), 'Copycat is not the owner';
        }
    };
};

subtest 'pagination' => sub {
    $ownable_documents_hit = 0;
    $apply_ownership_hit   = 0;

    is BOM::User::Script::POIOwnershipPopulator::run({limit => 4}), undef,                     'Script run successfully';
    is $apply_ownership_hit,                                        20 * scalar @broker_codes, 'ownership applied once (per broker)';
    is $ownable_documents_hit,                                      21 * scalar @broker_codes, 'queried the db once (per broker)';

    subtest 'owners' => sub {
        my $i = 0;

        for my $owner ($owners->@*) {
            my $client = $owner->{client};
            $i++;

            ok $client->documents->owned('passport', 'thefirstone' . $i, 'br'), 'Expected owner';
        }
    };

    subtest 'copycats' => sub {
        my $i = 0;

        for my $copycat ($copycats->@*) {
            my $client = $copycat->{client};
            $i++;

            ok !$client->documents->owned('passport', 'thefirstone' . $i, 'br'), 'Copycat is not the owner';
        }
    };

    $ownable_documents_hit = 0;
    $apply_ownership_hit   = 0;

    is BOM::User::Script::POIOwnershipPopulator::run({limit => 3}), undef,                     'Script run successfully';
    is $apply_ownership_hit,                                        27 * scalar @broker_codes, 'ownership applied once (per broker)';
    is $ownable_documents_hit,                                      27 * scalar @broker_codes, 'queried the db once (per broker)';

    subtest 'owners' => sub {
        my $i = 0;

        for my $owner ($owners->@*) {
            my $client = $owner->{client};
            $i++;

            ok $client->documents->owned('passport', 'thefirstone' . $i, 'br'), 'Expected owner';
        }
    };

    subtest 'copycats' => sub {
        my $i = 0;

        for my $copycat ($copycats->@*) {
            my $client = $copycat->{client};
            $i++;

            ok !$client->documents->owned('passport', 'thefirstone' . $i, 'br'), 'Copycat is not the owner';
        }
    };

    my $owners2 = seed(
        10,
        {
            type    => 'passport',
            country => 'br',
            prefix  => 'thesecond',
        });

    my $copycats2 = seed(
        11,
        {
            type    => 'passport',
            country => 'br',
            prefix  => 'thesecond',
        });

    $ownable_documents_hit = 0;
    $apply_ownership_hit   = 0;

    is BOM::User::Script::POIOwnershipPopulator::run({limit => 3}), undef,                     'Script run successfully';
    is $apply_ownership_hit,                                        34 * scalar @broker_codes, 'ownership applied once (per broker)';
    is $ownable_documents_hit,                                      34 * scalar @broker_codes, 'queried the db once (per broker)';

    subtest 'owners2' => sub {
        my $i = 0;

        for my $owner ($owners2->@*) {
            my $client = $owner->{client};
            $i++;

            ok $client->documents->owned('passport', 'thesecond' . $i, 'br'), 'Expected owner';
        }
    };

    subtest 'copycats2' => sub {
        my $i = 0;

        for my $copycat ($copycats2->@*) {
            my $client = $copycat->{client};
            $i++;

            if ($i > 10) {
                ok $client->documents->owned('passport', 'thesecond' . $i, 'br'), 'Last copycat is the owner';
            } else {
                ok !$client->documents->owned('passport', 'thesecond' . $i, 'br'), 'Copycat is not the owner';
            }
        }
    };

};

my $c = 0;

sub seed {
    my ($n, $args) = @_;

    my ($type, $country, $prefix) = @{$args}{qw/type country prefix/};

    my $stash = [];

    for my $i (1 .. $n) {
        $c++;

        my $user = BOM::User->create(
            email    => 'someclient' . $prefix . $c . '@binary.com',
            password => 'Secret0'
        );

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $user->add_client($client);
        $client->binary_user_id($user->id);
        $client->save;

        my $file_id = upload(
            $client,
            {
                document_type   => $type,
                page_type       => 'front',
                issuing_country => $country,
                document_format => 'PNG',
                checksum        => 'checkthis' . $i . $prefix,
                document_id     => $prefix . $i,
                status          => 'verified',
            });

        push $stash->@*,
            {
            file_id => $file_id,
            client  => $client
            };
    }

    return $stash;
}

sub upload {
    my ($client, $doc) = @_;

    my $file = $client->start_document_upload($doc);

    return $client->finish_document_upload($file->{file_id}, $doc->{status});
}

done_testing();
