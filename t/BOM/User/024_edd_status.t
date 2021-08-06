use strict;
use warnings;
use Test::More;
use Test::Deep qw(cmp_deeply);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $user = BOM::User->create(
    email    => 'edd@binary.com',
    password => 'test',
);

subtest 'update user edd status' => sub {
    ok $user->update_edd_status(
        status           => 'pending',
        start_date       => '2021-05-30',
        last_review_date => undef,
        average_earnings => {},
        comment          => 'hello'
        ),
        'can update user edd status';

    cmp_deeply(
        $user->get_edd_status(),
        {
            binary_user_id   => 1,
            last_review_date => undef,
            status           => 'pending',
            average_earnings => undef,
            start_date       => '2021-05-30 00:00:00',
            comment          => 'hello'
        },
        'edd status updated'
    );

    ok $user->update_edd_status(
        status           => 'in_progress',
        start_date       => '2021-05-30',
        last_review_date => undef,
        average_earnings => {
            currency => 'USD',
            amount   => 1000
        },
        comment => 'hello'
        ),
        'can update user edd status';

    cmp_deeply(
        $user->get_edd_status(),
        {
            binary_user_id   => 1,
            last_review_date => undef,
            status           => 'in_progress',
            average_earnings => '{"amount": 1000, "currency": "USD"}',
            start_date       => '2021-05-30 00:00:00',
            comment          => 'hello'
        },
        'edd status updated'
    );
};

done_testing;
