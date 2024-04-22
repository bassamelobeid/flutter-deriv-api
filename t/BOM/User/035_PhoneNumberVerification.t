use strict;
use warnings;

use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Database::UserDB;
use BOM::Config::Redis;
use BOM::User::PhoneNumberVerification;
use Date::Utility;

my $user;
my $pnv;

subtest 'The PNV object' => sub {
    $user = BOM::User->create(
        email    => 'pnvuser@deriv.com',
        password => 'xyz',
    );

    $pnv = $user->pnv;

    is ref($pnv), 'BOM::User::PhoneNumberVerification', 'Got a PNV';
};

subtest 'Phone Number is Verified' => sub {
    ok !$pnv->verified, 'Phone number is not verified';

    $pnv->update(1);

    ok !$pnv->verified, 'Phone number is (cached as) not verified';

    $user = BOM::User->new(id => $user->id);
    $pnv  = $user->pnv;

    ok $pnv->verified, 'Phone number is verified';

    $pnv->update(0);

    ok $pnv->verified, 'Phone number is (cached as) verified';

    $user = BOM::User->new(id => $user->id);
    $pnv  = $user->pnv;

    ok !$pnv->verified, 'Phone number is not verified';
};

subtest 'Next Attempt' => sub {
    is $pnv->next_attempt, 0, 'Empty redis is simply 0';

    my $redis = BOM::Config::Redis::redis_events_write();

    my $stamp = Date::Utility->new->epoch;

    $redis->set(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $user->id, $stamp);

    is $pnv->next_attempt, $stamp, 'Correct next attempt from redis';

    $pnv->update(1);

    $user = BOM::User->new(id => $user->id);
    $pnv  = $user->pnv;

    is $pnv->next_attempt, undef, 'No need for a next attempt when verified';
};

done_testing();
