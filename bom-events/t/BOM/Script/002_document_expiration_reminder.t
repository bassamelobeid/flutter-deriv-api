use strict;
use warnings;

use Test::MockModule;
use Test::More;
use Test::Deep;
use Test::Exception;

use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Event::Actions::Client;
use BOM::User;
use BOM::Platform::Context qw(request);
use List::Util;
use Date::Utility;
use BOM::User::Client::AuthenticationDocuments;
use BOM::User::Client::AuthenticationDocuments::Config;
use BOM::Event::Script::DocumentExpirationReminder;
use Test::MockTime qw(set_fixed_time);

my $reminder_mock  = Test::MockModule->new('BOM::Event::Script::DocumentExpirationReminder');
my $expiring_users = [];
my $fetch_calls    = 0;
my $notify_calls   = {};

my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $emissions    = [];
$emitter_mock->mock(
    'emit',
    sub {
        push $emissions->@*, +{@_};
        return undef;
    });

my $user = BOM::User->create(
    email          => 'someuser@binary.com',
    password       => 'heyyou!',
    email_verified => 1,
);

my $look_ahead        = +BOM::Event::Script::DocumentExpirationReminder::DOCUMENT_EXPIRATION_REMINDER_LOOK_AHEAD;
my $expected_lookback = +BOM::Event::Script::DocumentExpirationReminder::DOCUMENT_EXPIRATION_LOOK_BACK_DAYS;
my $soon_boundary     = Date::Utility->new->plus_time_interval($look_ahead . 'd');
my $now_boundary      = Date::Utility->new;
my $expected_expiration_at;
my $update_notified_at;
my $expiration;
my $groups;
my $lookback;
my $current_lookback;

$reminder_mock->mock(
    'update_notified_at',
    sub {
        $update_notified_at = 1;
    });

$reminder_mock->mock(
    'fetch_expiring_at',
    sub {
        (undef, $groups, $expiration, $lookback) = @_;

        if ($fetch_calls == 0) {
            is $lookback->date_yyyymmdd, $expiration->minus_time_interval($expected_lookback . 'd')->date_yyyymmdd, 'Expected look back date';
            $current_lookback = $lookback;
        } else {
            is($current_lookback->date_yyyymmdd, $lookback->date_yyyymmdd, 'lookback is not expected to change at the same loop');
        }

        # not much can be said about the dates
        is($expiration->date_yyyymmdd, $expected_expiration_at->date_yyyymmdd, 'Expected expiration date');

        # ideally we don't have to hardcode the expected groups
        # we can just regex grep them and reduce it to a boolean AND chain (a.k.a. `all` in the List::Util package)

        ok((List::Util::all { $_ =~ /^real/ && ($_ =~ /\\vanuatu_/ || $_ =~ /\\bvi_/ || $_ =~ /\\labuan_/) } $groups->@*), 'Expected groups');

        ++$fetch_calls;

        # try to simulate the sandwiching with ties
        my $last;
        my $counter = 0;
        my $tie;
        my $stop_tie;

        my @slice = grep {
            my $user_expiration = Date::Utility->new($_->{expiration_date});
            $tie  = $last if $counter >= 50;
            $last = $user_expiration;

            $stop_tie = 1 if $tie && $user_expiration->date_yyyymmdd ne $tie->date_yyyymmdd;

            my $filter = (!$tie || (!$stop_tie && $user_expiration->date_yyyymmdd eq $tie->date_yyyymmdd))
                && Date::Utility->new($user_expiration->date_yyyymmdd)
                ->is_after(Date::Utility->new($lookback->date_yyyymmdd)->minus_time_interval('1d'))
                && Date::Utility->new($user_expiration->date_yyyymmdd)
                ->is_before(Date::Utility->new($expiration->date_yyyymmdd)->plus_time_interval('1d'));

            $counter++ if $filter;
            $filter;

        } @$expiring_users;

        my $last_tie = $slice[-1];

        $expected_expiration_at = Date::Utility->new($last_tie->{expiration_date})->minus_time_interval('1d') if $last_tie;

        return [@slice];
    });

$reminder_mock->mock(
    'notify_soon_to_be_expired',
    sub {
        my (undef, $record) = @_;

        my $binary_user_id = $record->{binary_user_id};

        ok !$notify_calls->{$binary_user_id}, 'Notify ' . $record->{binary_user_id};

        $notify_calls->{$binary_user_id} = 1;

        return $reminder_mock->original('notify_soon_to_be_expired')->(@_);
    });

$reminder_mock->mock(
    'notify_expiring_today',
    sub {
        my (undef, $record) = @_;

        my $binary_user_id = $record->{binary_user_id};

        ok !$notify_calls->{$binary_user_id}, 'Notify ' . $record->{binary_user_id};

        $notify_calls->{$binary_user_id} = 1;

        return $reminder_mock->original('notify_expiring_today')->(@_);
    });

subtest 'document expiring soon reminder' => sub {
    $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');

    my $expected_epoch = $expected_expiration_at->epoch;
    set_fixed_time($expected_epoch);

    # disable the expiring today to avoid mock clashing
    $reminder_mock->mock(
        'expiring_today',
        sub {
            return Future->done;
        });

    my $reminder = BOM::Event::Script::DocumentExpirationReminder->new();
    isa_ok $reminder, 'BOM::Event::Script::DocumentExpirationReminder', 'Expected instance of script';

    subtest 'empty list' => sub {
        $emissions = [];

        $fetch_calls = 0;

        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 1, 'Fetch call';

        cmp_deeply $notify_calls, +{}, 'No notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'list outside the sandwich (past)' => sub {
        $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');
        $emissions              = [];

        $expiring_users = [
            map {
                +{
                    binary_user_id  => -$_,
                    expiration_date =>
                        Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval($expected_lookback . 'd')->minus_time_interval('1d')}
            } 1 .. 10
        ];
        $fetch_calls  = 0;
        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 1, 'Expected fetch calls';    # expiration dates didn't hit the sandwich (hardcoded way in the past)

        cmp_deeply $notify_calls, +{}, 'No notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'whole list in the sandwich with ties (lower boundary)' => sub {
        $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');
        $emissions              = [];

        $expiring_users = [
            map {
                +{
                    binary_user_id  => -$_,
                    expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval($expected_lookback . 'd')}
            } 1 .. 10
        ];
        $fetch_calls  = 0;
        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 2, 'Expected fetch calls';    # they are all tied!

        cmp_deeply $notify_calls, +{map { ($_->{binary_user_id} => 1) } grep { $_ } $expiring_users->@*}, 'Expected notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'whole list in the sandwich with ties (upper boundary)' => sub {
        $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');
        $emissions              = [];

        $expiring_users = [map { +{binary_user_id => -$_, expiration_date => $soon_boundary->date_yyyymmdd} } 1 .. 10];
        $fetch_calls    = 0;
        $notify_calls   = {};

        $reminder->run()->get;

        is $fetch_calls, 2, 'Expected fetch calls';    # they are all tied!

        cmp_deeply $notify_calls, +{map { ($_->{binary_user_id} => 1) } grep { $_ } $expiring_users->@*}, 'Expected notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'list outside the sandwich (future)' => sub {
        $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');
        $emissions              = [];

        $expiring_users = [
            map {
                +{
                    binary_user_id  => -$_,
                    expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->plus_time_interval('1d')->date_yyyymmdd
                }
            } 1 .. 10
        ];
        $fetch_calls  = 0;
        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 1, 'Expected fetch calls';    # expiration dates didn't hit the sandwich

        cmp_deeply $notify_calls, +{}, 'No notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'mixed list with proper real ties' => sub {
        $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');
        $emissions              = [];

        $expiring_users = [];
        push $expiring_users->@*,
            map { +{binary_user_id => -$_, expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->date_yyyymmdd} } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 10,
                expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval('1d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 20,
                expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval('2d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 30,
                expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval('3d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 40,
                expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval('4d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 50,
                expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval('5d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 60,
                expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval('6d')->date_yyyymmdd
            }
        } 1 .. 65;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 125,
                expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval('1y')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 135,
                expiration_date => Date::Utility->new($soon_boundary->date_yyyymmdd)->minus_time_interval('2y')->date_yyyymmdd
            }
        } 1 .. 10;

        $fetch_calls  = 0;
        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 3, 'Expected fetch calls';    # they are all tied!

        my @expected = $expiring_users->@*;
        cmp_deeply $notify_calls, +{map { ($_->{binary_user_id} => 1) } grep { $_->{binary_user_id} >= -125 } $expiring_users->@*},
            'Expected notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'having real users/clients' => sub {
        subtest 'no real client' => sub {
            $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');

            $emissions = [];

            $expiring_users = [{binary_user_id => $user->id, expiration_date => $soon_boundary->date_yyyymmdd}];

            $fetch_calls = 0;

            $notify_calls = {};

            $reminder->run()->get;

            is $fetch_calls, 2, 'Fetch call';

            cmp_deeply $notify_calls,
                +{
                $user->id => 1,
                },
                'Notify call';

            cmp_bag $emissions, [], 'No emissions';
        };

        subtest 'having dubious loginid' => sub {
            $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');

            my $user_mock = Test::MockModule->new('BOM::User');
            my @real_loginids;
            $user_mock->mock(
                'bom_real_loginids',
                sub {
                    return @real_loginids;
                });

            @real_loginids = ('CR0');

            $emissions = [];

            $expiring_users = [{binary_user_id => $user->id, expiration_date => $soon_boundary->date_yyyymmdd}];

            $fetch_calls = 0;

            $notify_calls = {};

            $reminder->run()->get;

            is $fetch_calls, 2, 'Fetch call';

            cmp_deeply $notify_calls,
                +{
                $user->id => 1,
                },
                'Notify call';

            cmp_bag $emissions, [], 'No emissions';

            $user_mock->unmock_all;
        };

        subtest 'having legit loginid' => sub {
            $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');

            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code    => 'CR',
                email          => $user->email,
                binary_user_id => $user->id,
            });
            $user->add_client($client);

            $emissions = [];

            $expiring_users = [{binary_user_id => $user->id, expiration_date => $soon_boundary->date_yyyymmdd}];

            $fetch_calls = 0;

            $notify_calls = {};

            $reminder->run()->get;

            is $fetch_calls, 2, 'Fetch call';

            cmp_deeply $notify_calls,
                +{
                $user->id => 1,
                },
                'Notify call';

            cmp_bag $emissions,
                [{
                    document_expiring_soon => {
                        loginid    => $client->loginid,
                        properties => {
                            expiration_date    => re('\d+'),
                            authentication_url => request->brand->authentication_url,
                            live_chat_url      => request->brand->live_chat_url,
                            email              => $client->email,
                        }}}
                ],
                'Expected emissions';

            ok $reminder->notify_locked({
                    binary_user_id => $user->id,
                })->get, 'User is locked';
        };

        subtest 'having legit loginid but locked down' => sub {
            $expected_expiration_at = Date::Utility->new->plus_time_interval($look_ahead . 'd');

            $emissions = [];

            $expiring_users = [{binary_user_id => $user->id, expiration_date => $soon_boundary->date_yyyymmdd}];

            $fetch_calls = 0;

            $notify_calls = {};

            $reminder->run()->get;

            is $fetch_calls, 2, 'Fetch call';

            cmp_deeply $notify_calls,
                +{
                $user->id => 1,
                },
                'Notify call';

            cmp_bag $emissions, [], 'Expected emissions';

            ok $reminder->notify_locked({
                    binary_user_id => $user->id,
                })->get, 'User is locked';
        };
    };
};

subtest 'document expiring today' => sub {
    $expected_expiration_at = Date::Utility->new;

    # disable the expiring soon to avoid mock clashing
    $reminder_mock->mock(
        'soon_to_be_expired',
        sub {
            return Future->done;
        });
    $reminder_mock->unmock('expiring_today');

    my $reminder = BOM::Event::Script::DocumentExpirationReminder->new();

    isa_ok $reminder, 'BOM::Event::Script::DocumentExpirationReminder', 'Expected instance of script';

    $reminder->redis->del(+BOM::Event::Script::DocumentExpirationReminder::DOCUMENT_EXPIRATION_REMINDER_LOCK . $user->id)->get;

    subtest 'empty list' => sub {
        $emissions = [];

        $fetch_calls = 0;

        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 1, 'Fetch call';

        cmp_deeply $notify_calls, +{}, 'No notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'list outside the sandwich (past)' => sub {
        $expected_expiration_at = Date::Utility->new;
        $emissions              = [];

        $expiring_users = [
            map {
                +{
                    binary_user_id  => -$_,
                    expiration_date =>
                        Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval($expected_lookback . 'd')->minus_time_interval('1d')}
            } 1 .. 10
        ];
        $fetch_calls  = 0;
        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 1, 'Expected fetch calls';    # expiration dates didn't hit the sandwich (hardcoded way in the past)

        cmp_deeply $notify_calls, +{}, 'No notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'whole list in the sandwich with ties (lower boundary)' => sub {
        $expected_expiration_at = Date::Utility->new;
        $emissions              = [];

        $expiring_users = [
            map {
                +{
                    binary_user_id  => -$_,
                    expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval($expected_lookback . 'd')}
            } 1 .. 10
        ];
        $fetch_calls  = 0;
        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 2, 'Expected fetch calls';    # they are all tied!

        cmp_deeply $notify_calls, +{map { ($_->{binary_user_id} => 1) } grep { $_ } $expiring_users->@*}, 'Expected notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'whole list in the sandwich with ties (upper boundary)' => sub {
        $expected_expiration_at = Date::Utility->new;
        $emissions              = [];

        $expiring_users = [map { +{binary_user_id => -$_, expiration_date => $now_boundary->date_yyyymmdd} } 1 .. 10];
        $fetch_calls    = 0;
        $notify_calls   = {};

        $reminder->run()->get;

        is $fetch_calls, 2, 'Expected fetch calls';    # they are all tied!

        cmp_deeply $notify_calls, +{map { ($_->{binary_user_id} => 1) } grep { $_ } $expiring_users->@*}, 'Expected notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'list outside the sandwich (future)' => sub {
        $expected_expiration_at = Date::Utility->new;
        $emissions              = [];

        $expiring_users = [
            map {
                +{
                    binary_user_id  => -$_,
                    expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->plus_time_interval('1d')->date_yyyymmdd
                }
            } 1 .. 10
        ];
        $fetch_calls  = 0;
        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 1, 'Expected fetch calls';    # expiration dates didn't hit the sandwich

        cmp_deeply $notify_calls, +{}, 'No notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'mixed list with proper real ties' => sub {
        $expected_expiration_at = Date::Utility->new;
        $emissions              = [];

        $expiring_users = [];
        push $expiring_users->@*,
            map { +{binary_user_id => -$_, expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->date_yyyymmdd} } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 10,
                expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval('1d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 20,
                expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval('2d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 30,
                expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval('3d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 40,
                expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval('4d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 50,
                expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval('5d')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 60,
                expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval('6d')->date_yyyymmdd
            }
        } 1 .. 65;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 125,
                expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval('1y')->date_yyyymmdd
            }
        } 1 .. 10;

        push $expiring_users->@*, map {
            +{
                binary_user_id  => -$_ - 135,
                expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)->minus_time_interval('2y')->date_yyyymmdd
            }
        } 1 .. 10;

        $fetch_calls  = 0;
        $notify_calls = {};

        $reminder->run()->get;

        is $fetch_calls, 3, 'Expected fetch calls';    # they are all tied!

        my @expected = $expiring_users->@*;
        cmp_deeply $notify_calls, +{map { ($_->{binary_user_id} => 1) } grep { $_->{binary_user_id} >= -125 } $expiring_users->@*},
            'Expected notifications sent';

        cmp_bag $emissions, [], 'No emissions';
    };

    subtest 'having real users/clients' => sub {
        subtest 'no real client' => sub {
            $expected_expiration_at = Date::Utility->new;
            my $user_mock = Test::MockModule->new('BOM::User');
            $user_mock->mock(
                'bom_real_loginids',
                sub {
                    return ();
                });

            $emissions = [];

            $update_notified_at = 0;

            $expiring_users = [{binary_user_id => $user->id, expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)}];

            $fetch_calls = 0;

            $notify_calls = {};

            $reminder->run()->get;

            is $fetch_calls, 2, 'Fetch call';

            cmp_deeply $notify_calls,
                +{
                $user->id => 1,
                },
                'Notify call';

            cmp_bag $emissions, [], 'No emissions';

            ok !$update_notified_at, 'no notifications';

            $user_mock->unmock_all;
        };

        subtest 'having dubious loginid' => sub {
            $expected_expiration_at = Date::Utility->new;
            my $user_mock = Test::MockModule->new('BOM::User');
            my @real_loginids;
            $user_mock->mock(
                'bom_real_loginids',
                sub {
                    return @real_loginids;
                });

            @real_loginids = ('CR0');

            $emissions = [];

            $update_notified_at = 0;

            $expiring_users = [{binary_user_id => $user->id, expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)}];

            $fetch_calls = 0;

            $notify_calls = {};

            $reminder->run()->get;

            is $fetch_calls, 2, 'Fetch call';

            cmp_deeply $notify_calls,
                +{
                $user->id => 1,
                },
                'Notify call';

            cmp_bag $emissions, [], 'No emissions';

            ok !$update_notified_at, 'no notifications';

            $user_mock->unmock_all;
        };

        subtest 'having legit loginid' => sub {
            $expected_expiration_at = Date::Utility->new;
            my ($loginid) = $user->bom_real_loginids;
            my $client = BOM::User::Client->new({loginid => $loginid});

            $emissions = [];

            $update_notified_at = 0;

            $expiring_users = [{binary_user_id => $user->id, expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)}];

            $fetch_calls = 0;

            $notify_calls = {};

            $reminder->run()->get;

            is $fetch_calls, 2, 'Fetch call';

            cmp_deeply $notify_calls,
                +{
                $user->id => 1,
                },
                'Notify call';

            cmp_bag $emissions,
                [{
                    document_expiring_today => {
                        loginid    => $loginid,
                        properties => {
                            authentication_url => request->brand->authentication_url,
                            live_chat_url      => request->brand->live_chat_url,
                            email              => $client->email,
                        }}}
                ],
                'Expected emissions';

            ok $update_notified_at, 'notification stamp updated';

            ok $reminder->notify_locked({
                    binary_user_id => $user->id,
                })->get, 'User is locked';
        };

        subtest 'having legit loginid but locked down' => sub {
            $expected_expiration_at = Date::Utility->new;
            $emissions              = [];

            $expiring_users = [{binary_user_id => $user->id, expiration_date => Date::Utility->new($now_boundary->date_yyyymmdd)}];

            $update_notified_at = 0;

            $fetch_calls = 0;

            $notify_calls = {};

            $reminder->run()->get;

            is $fetch_calls, 2, 'Fetch call';

            cmp_deeply $notify_calls,
                +{
                $user->id => 1,
                },
                'Notify call';

            cmp_bag $emissions, [], 'Expected emissions';

            ok $reminder->notify_locked({
                    binary_user_id => $user->id,
                })->get, 'User is locked';

            ok !$update_notified_at, 'notification not updated';
        };
    };
};

$reminder_mock->unmock_all;
$emitter_mock->unmock_all;

done_testing();
