use strict;
use warnings;

use Test::Exception;
use Test::MockModule;
use Test::More;

use BOM::Config::Redis;
use BOM::OAuth::Common::Throttler;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $redis = BOM::Config::Redis::redis_auth_write();

my ($key, $id);

subtest "identified user should get disabled after consecutive attempts" => sub {
    my $clients = create_clients('test-disable@deriv.com', ['CR', 'VRTC', 'MF']);
    my $user_id = $clients->[1]->user->id;

    ($key, $id) = ('binary_user_id', $user_id);
    set_counter(
        $key => $id,
        6
    );

    repeat_failed_attempt(
        3,
        undef,
        key        => 'email',
        identifier => 'test-disable@deriv.com'
    );

    is get_counter('email' => 'test-disable@deriv.com'), undef, 'Count is correct';
    is get_counter($key    => $id),                      9,     'Count is correct';

    repeat_failed_attempt(
        3,
        undef,
        key        => 'email',
        identifier => 'test-disable@deriv.com'
    );

    is get_counter($key => $id), undef, 'Count is correct';
    is get_round($key => $id),   0,     'Round is correct';
    is get_backoff($key => $id), undef, 'Backoff enabled';

    ok $clients->[0]->status->disabled, 'client cr has been disabled';
    is $clients->[0]->status->disabled->{reason}, 'Too many failed login attempts', 'disable reason is correct';

    ok $clients->[1]->status->disabled, 'client vr has been disabled';
    is $clients->[1]->status->disabled->{reason}, 'Too many failed login attempts', 'disable reason is correct';

    ok $clients->[2]->status->disabled, 'client mf has been disabled';
    is $clients->[2]->status->disabled->{reason}, 'Too many failed login attempts', 'disable reason is correct';
};

subtest "counter ttl should get updated per failed attempt" => sub {
    ($key, $id) = ('ip', '172.1.1.1');

    my $failure_counter_key = join '::', (BOM::OAuth::Common::Throttler->FAILURE_COUNTER_KEY, $key, $id);

    repeat_failed_attempt(
        1,
        undef,
        key        => $key,
        identifier => $id
    );

    my $counter_ttl = $redis->ttl($failure_counter_key);

    ok $counter_ttl > BOM::OAuth::Common::Throttler->COUNTER_TTL / 2, 'counter ttl is more than half a day';

    sleep 1;

    $counter_ttl = $redis->ttl($failure_counter_key);

    repeat_failed_attempt(
        1,
        undef,
        key        => $key,
        identifier => $id
    );

    my $counter_ttl_next = $redis->ttl($failure_counter_key);

    ok $counter_ttl_next > $counter_ttl, 'New attempt has updated the counter ttl';
};

subtest "Sequence of IP login failures" => sub {
    ($key, $id) = ('ip', '174.254.254.0');
    my @plans = ({
            attempts => 1,
            round    => 1,
            backoff  => undef,
        },
        {
            attempts => 2,
            round    => 1,
            backoff  => undef,
        },
        {
            attempts => 3,
            round    => 1,
            backoff  => 240,
        },
        {
            attempts => 4,
            round    => 1,
            backoff  => 480,
        },
        {
            attempts => 5,
            round    => 1,
            backoff  => 900,
        },
        {
            attempts => 6,
            round    => 2,
            backoff  => undef,
        },
        {
            attempts => 7,
            round    => 2,
            backoff  => 720,
        },
        {
            attempts => 8,
            round    => 2,
            backoff  => 1440,
        },
        {
            attempts => 9,
            round    => 2,
            backoff  => 2880,
        },
        {
            attempts => 10,
            round    => 2,
            backoff  => 3600,
        },
        {
            attempts => 11,
            round    => 3,
            backoff  => 360,
        },
        {
            attempts => 12,
            round    => 3,
            backoff  => 720,
        },
        {
            attempts => 24,
            round    => 5,
            backoff  => 2880,
        });

    for my $case (@plans) {
        note sprintf 'Making %s attempts', $case->{attempts};
        reset_throttler($key => $id);

        repeat_failed_attempt(
            $case->{attempts},
            sub {
                reset_backoff($key, $id);
            },
            key           => $key,
            identifier    => $id,
            clear_backoff => 1
        );

        is get_counter($key => $id), $case->{attempts}, 'Count is correct';
        is get_round($key => $id),   $case->{round},    'Round is correct';
        is get_backoff($key => $id), $case->{backoff},  'Backoff is correct';

        if ($case->{backoff}) {
            dies_ok { BOM::OAuth::Common::Throttler::inspect_failed_login_attempts($key => $id) } 'Punishment applied is correct';
        } else {
            is BOM::OAuth::Common::Throttler::inspect_failed_login_attempts($key => $id), undef, 'No Punishment is correct';
        }
    }
};

subtest "Sequence of non-identified email login failures" => sub {
    ($key, $id) = ('email', 'unregistered@deriv.com');
    my @plans = ({
            attempts => 1,
            round    => 1,
            backoff  => undef,
        },
        {
            attempts => 2,
            round    => 1,
            backoff  => undef,
        },
        {
            attempts => 3,
            round    => 1,
            backoff  => 240,
        },
        {
            attempts => 4,
            round    => 1,
            backoff  => 480,
        },
        {
            attempts => 5,
            round    => 1,
            backoff  => 900,
        },
        {
            attempts => 6,
            round    => 2,
            backoff  => undef,
        },
        {
            attempts => 7,
            round    => 2,
            backoff  => 720,
        },
        {
            attempts => 8,
            round    => 2,
            backoff  => 1440,
        },
        {
            attempts => 9,
            round    => 2,
            backoff  => 2880,
        },
        {
            attempts => 10,
            round    => 2,
            backoff  => 3600,
        },
        {
            attempts => 11,
            round    => 3,
            backoff  => 360,
        },
        {
            attempts => 12,
            round    => 3,
            backoff  => 720,
        },
        {
            attempts => 24,
            round    => 5,
            backoff  => 2880,
        });

    for my $case (@plans) {
        note sprintf 'Making %s attempts', $case->{attempts};
        reset_throttler($key => $id);

        repeat_failed_attempt(
            $case->{attempts},
            sub {
                reset_backoff($key, $id);
            },
            key           => $key,
            identifier    => $id,
            clear_backoff => 1
        );

        is get_counter($key => $id), $case->{attempts}, 'Count is correct';
        is get_round($key => $id),   $case->{round},    'Round is correct';
        is get_backoff($key => $id), $case->{backoff},  'Backoff is correct';

        if ($case->{backoff}) {
            dies_ok { BOM::OAuth::Common::Throttler::inspect_failed_login_attempts($key => $id) } 'Punishment applied is correct';
        } else {
            is BOM::OAuth::Common::Throttler::inspect_failed_login_attempts($key => $id), undef, 'No Punishment is correct';
        }
    }
};

subtest "Sequence of identified email login failures" => sub {
    my $clients = create_clients('disable+account@deriv.com', ['CR', 'VRTC', 'MF']);
    my $user_id = $clients->[0]->user->id;

    ok !$clients->[0]->status->disabled, 'client cr is enabled';
    ok !$clients->[1]->status->disabled, 'client vr is enabled';
    ok !$clients->[2]->status->disabled, 'client mf is enabled';

    ($key, $id) = ('binary_user_id', $user_id);
    my @plans = ({
            attempts          => 1,
            round             => 1,
            backoff           => undef,
            accounts_disabled => 0,
        },
        {
            attempts          => 2,
            round             => 1,
            backoff           => undef,
            accounts_disabled => 0,
        },
        {
            attempts          => 3,
            round             => 1,
            backoff           => 240,
            accounts_disabled => 0,
        },
        {
            attempts          => 4,
            round             => 1,
            backoff           => 480,
            accounts_disabled => 0,
        },
        {
            attempts          => 5,
            round             => 1,
            backoff           => 900,
            accounts_disabled => 0,
        },
        {
            attempts          => 6,
            round             => 2,
            backoff           => undef,
            accounts_disabled => 0,
        },
        {
            attempts          => 7,
            round             => 2,
            backoff           => 720,
            accounts_disabled => 0,
        },
        {
            attempts          => 8,
            round             => 2,
            backoff           => 1440,
            accounts_disabled => 0,
        },
        {
            attempts          => 9,
            round             => 2,
            backoff           => 2880,
            accounts_disabled => 0,
        },
        {
            attempts          => 10,
            round             => 2,
            backoff           => 3600,
            accounts_disabled => 0,
        },
        {
            attempts          => 11,
            accounts_disabled => 1,
        },
        {
            attempts          => 12,
            accounts_disabled => 1,
        },
        {
            attempts          => 24,
            accounts_disabled => 1,
        });

    for my $case (@plans) {
        note sprintf 'Making %s attempts', $case->{attempts};
        reset_throttler($key => $id);

        repeat_failed_attempt(
            $case->{attempts},
            sub {
                reset_backoff($key, $id);
            },
            key           => 'email',
            identifier    => 'disable+account@deriv.com',
            clear_backoff => 1
        );

        if ($case->{accounts_disabled}) {
            is get_counter($key => $id), undef, 'Count is correct';
            is get_round($key => $id),   0,     'Round is correct';
            is get_backoff($key => $id), undef, 'Backoff is correct';
        } else {
            is get_counter($key => $id), $case->{attempts}, 'Count is correct';
            is get_round($key => $id),   $case->{round},    'Round is correct';
            is get_backoff($key => $id), $case->{backoff},  'Backoff is correct';
        }

        if ($case->{backoff}) {
            dies_ok { BOM::OAuth::Common::Throttler::inspect_failed_login_attempts(email => 'disable+account@deriv.com') }
            'Punishment applied is correct';
        } else {
            is BOM::OAuth::Common::Throttler::inspect_failed_login_attempts(email => 'disable+account@deriv.com'), undef, 'No Punishment is correct';
        }
    }
};

sub repeat_failed_attempt {
    my ($count, $precall, %args) = @_;
    for (1 .. $count) {
        $precall ? $precall->() : undef;

        BOM::OAuth::Common::Throttler::failed_login_attempt($args{key} => $args{identifier});
    }
}

sub set_counter {
    my ($key, $identifier, $counter) = @_;

    my $failure_counter_key = join '::', (BOM::OAuth::Common::Throttler->FAILURE_COUNTER_KEY, $key, $identifier);

    $redis->set($failure_counter_key, $counter);
}

sub get_counter {
    my ($key, $identifier) = @_;

    my $failure_counter_key = join '::', (BOM::OAuth::Common::Throttler->FAILURE_COUNTER_KEY, $key, $identifier);

    return $redis->get($failure_counter_key);
}

sub get_round {
    my ($key, $identifier) = @_;

    my $failure_counter_key = join '::', (BOM::OAuth::Common::Throttler->FAILURE_COUNTER_KEY, $key, $identifier);
    my $count               = $redis->get($failure_counter_key) // 0;

    return BOM::OAuth::Common::Throttler::_get_round($count);
}

sub get_backoff {
    my ($key, $identifier) = @_;

    my $backoff_key = join '::', (BOM::OAuth::Common::Throttler->BACKOFF_KEY, $key, $identifier);

    return $redis->get($backoff_key);
}

sub reset_throttler {
    my ($key, $identifier) = @_;

    my $failure_counter_key = join '::', (BOM::OAuth::Common::Throttler->FAILURE_COUNTER_KEY, $key, $identifier);

    $redis->del($failure_counter_key);
    reset_backoff($key, $identifier);
}

sub reset_backoff {
    my ($key, $identifier) = @_;

    my $backoff_key = join '::', (BOM::OAuth::Common::Throttler->BACKOFF_KEY, $key, $identifier);

    $redis->del($backoff_key);
}

sub create_clients {
    my ($email, $broker_codes) = @_;

    my $hash_pwd = BOM::User::Password::hashpw('123Abc');
    my $user     = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    my @clients = ();

    for my $code ($broker_codes->@*) {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => $code,
        });
        $client->email($email);
        $client->save;

        $user->add_client($client);

        push @clients, $client;
    }

    return \@clients;
}

done_testing
