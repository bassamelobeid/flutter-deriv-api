use strict;
use warnings;

use Test::More;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Scalar::Util                               qw(refaddr);

my $user = BOM::User->create(
    email    => 'docuser@test.com',
    password => 'secret',
);

my $user2 = BOM::User->create(
    email    => 'docuser2@test.com',
    password => 'secret',
);

subtest 'documents instance' => sub {
    my $documents = $user->documents;

    isa_ok $documents, 'BOM::User::Documents', 'expected instance returned';

    is refaddr($user->documents), refaddr($documents), 'cached documents object';

    isnt refaddr($user->documents), refaddr($user2->documents), 'different object for different user';

    is refaddr($user->documents->user), refaddr($user), 'weak ref!';

    is refaddr($user2->documents->user), refaddr($user2), 'weak ref!';
};

subtest 'POI ownership' => sub {
    is $user->documents->poi_ownership('passport', '00-00-00-00', 'br'),  undef, 'no document has been claimed';
    is $user2->documents->poi_ownership('passport', '00-00-00-00', 'br'), undef, 'no document has been claimed';

    $user->documents->poi_claim('passport', '00-00-00-00', 'br');

    is $user->documents->poi_ownership('passport', '00-00-00-00', 'br'),  $user->id, 'document claimed';
    is $user2->documents->poi_ownership('passport', '00-00-00-00', 'br'), $user->id, 'document claimed';

    is $user->documents->poi_ownership('national_id', '00-00-00-00', 'br'),  undef, 'not claimed';
    is $user2->documents->poi_ownership('national_id', '00-00-00-00', 'br'), undef, 'not claimed';
    is $user->documents->poi_ownership('passport', '00-00-00-00', 'ar'),     undef, 'not claimed';
    is $user2->documents->poi_ownership('passport', '00-00-00-00', 'ar'),    undef, 'not claimed';

    $user2->documents->poi_claim('passport', '00-00-00-00', 'ar');

    is $user->documents->poi_ownership('passport', '00-00-00-00', 'ar'),  $user2->id, 'document claimed';
    is $user2->documents->poi_ownership('passport', '00-00-00-00', 'ar'), $user2->id, 'document claimed';

    $user->documents->poi_claim('passport', '00-00-00-00', 'ar');

    is $user->documents->poi_ownership('passport', '00-00-00-00', 'ar'),  $user2->id, 'document claimed';
    is $user2->documents->poi_ownership('passport', '00-00-00-00', 'ar'), $user2->id, 'document claimed';

    $user->documents->poi_free('passport', '00-00-00-00', 'br');
    is $user->documents->poi_ownership('passport', '00-00-00-00', 'br'), undef, 'the document is now free';

    $user->documents->poi_free('passport', '00-00-00-00', 'br');
    is $user->documents->poi_ownership('passport', '00-00-00-00', 'ar'),  $user2->id, 'document claimed (u1 cannot free it)';
    is $user2->documents->poi_ownership('passport', '00-00-00-00', 'ar'), $user2->id, 'document claimed (u1 cannot free it)';

    $user2->documents->poi_free('passport', '00-00-00-00', 'ar');
    is $user->documents->poi_ownership('passport', '00-00-00-00', 'ar'),  undef, 'the document is now free';
    is $user2->documents->poi_ownership('passport', '00-00-00-00', 'ar'), undef, 'the document is now free';

};

done_testing();
