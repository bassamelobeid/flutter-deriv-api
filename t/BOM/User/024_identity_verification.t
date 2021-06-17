use strict;
use warnings;
use Test::More;
use Test::Deep;

use BOM::User::IdentityVerification;

my $idv = BOM::User::IdentityVerification->new(user_id => 'space_cowboy');

isa_ok $idv, 'BOM::User::IdentityVerification';
is $idv->user_id, 'space_cowboy', 'Adios vaquero';

# you gotta carry that weight (of incomplete implementation)
# TODO: proper testing once the proper implementation arrives

subtest 'Rejected Reasons' => sub {
    cmp_bag $idv->get_rejected_reasons, [], 'Expected rejected reasons';
};

subtest 'Submissions Left' => sub {
    is $idv->submissions_left, 0, 'Expected submissions left';
};

subtest 'Limit per user' => sub {
    is $idv->limit_per_user, 0, 'Expected limit per user';
};

subtest 'Reported properties' => sub {
    cmp_deeply $idv->reported_properties, {}, 'Expected reported properties';
};

subtest 'Status' => sub {
    cmp_deeply $idv->status, 'none', 'Expected status';
};

done_testing();
