package BOM::OAuth::Common::Throttler;

use strict;
use warnings;
no indirect;

use Algorithm::Backoff;
use DataDog::DogStatsd::Helper qw( stats_inc );

use BOM::Config::Runtime;
use BOM::User;

use constant FAILURE_COUNTER_KEY => 'oauth::throttler::failure_count';
use constant BACKOFF_KEY         => 'oauth::throttler::backoff';

use constant FIRST_ROUND_TRIGGER_COUNT  => 5;
use constant SUBSEQ_ROUND_TRIGGER_COUNT => 2;

use constant ROUND_WINDOW => 5;

use constant FIRST_ROUND_MIN_BACKOFF => 30;        # in seconds
use constant FIRST_ROUND_MAX_BACKOFF => 15 * 60;

use constant SUBSEQ_ROUND_MIN_BACKOFF => 3 * 60;
use constant SUBSEQ_ROUND_MAX_BACKOFF => 1 * 60 * 60;

use constant COUNTER_TTL => 1 * 24 * 60 * 60;      # 1 day in seconds

use constant USER_BLOCK_TRIGGER_COUNT => 10;

=head2 failed_login_attempt

Increments the failed login attempts and might apply restriction on either client IP or email

If no arguments passed, it will only increment statistics

=over 4

=item * C<ip> - (optional) client ip

=item * C<email> - (optional) client email

=back

Returns C<undef>.

=cut

sub failed_login_attempt {
    my %args = @_;

    my $email = $args{email};
    my $ip    = $args{ip};

    stats_inc('login.authorizer.login_failed');

    _failed_login_by_ip($ip) if $ip;

    _failed_login_by_email($email) if $email;

    return undef;
}

=head2 _failed_login_by_email

Applies the login failure punishment on user
based on email if the user doesn't exists otherwise
based on user id if the client is not disabled.

For identified user attempts:
The disable status will be set when the round counter is
2 which means user tried more than 10 attempts to login
to their account and due to security reasons, we will 
disable all of the accounts.

Once client disabled, all throttle restrictions will lift off.

=over 4

=item * C<$email> - the offending email

=back

Returns C<undef>.

=cut

sub _failed_login_by_email {
    my $email = shift;

    my $client;

    my $user = BOM::User->new(email => $email);
    if ($user) {
        my @clients = $user->clients(include_self_closed => 1);
        $client = $clients[0];

        # Disabled clients are excluded, if nothing found => all are disabled
        return undef unless $client;
    }

    my $redis = BOM::Config::Redis::redis_auth();

    my ($key, $identifier) = $user ? ('binary_user_id', $user->id) : ('email', $email);

    my $failure_counter_key = join '::', (FAILURE_COUNTER_KEY, $key, $identifier);
    my $backoff_key         = join '::', (BACKOFF_KEY,         $key, $identifier);

    my $failure_count = $redis->get($failure_counter_key) // 0;

    if ($user) {
        if ($failure_count >= USER_BLOCK_TRIGGER_COUNT) {
            $client->propagate_status(
                'disabled',
                'system',
                'Too many failed login attempts',
                {
                    include_virtual => 1,
                });

            stats_inc('login.authorizer.block.account_disabled');

            $redis->del($failure_counter_key, $backoff_key);
        } else {
            _increment_failed_attempt('binary_user_id', $user->id);
        }
    } else {
        _increment_failed_attempt('email', $email);
    }

    return undef;
}

=head2 _failed_login_by_ip

Applies the login failure punishment on user based on IP

=over 4

=item * C<$ip> - the offending ip address

=back

Returns undef.

=cut

sub _failed_login_by_ip {
    my $ip = shift;

    _increment_failed_attempt('ip', $ip);

    return undef;
}

=head2 _increment_failed_attempt

Handles incrementing logic for failed attempt based on provided criteria.

Round refers to B<ROUND_WINDOW> times of consecutive failed attempt.
For the first round we ignore B<FIRST_ROUND_TRIGGER_COUNT> and for the subsequest 
rounds we ignore B<SUBSEQ_ROUND_TRIGGER_COUNT> consecutive failed attempts.

Once the client reached the threshold of round of attempts, we throttle next auth actions based on
their either IP or email (whatever provided), also the expiration of throttler will 
be extended per failed attempts based on L<Algorithm::Backoff>.

=over 4

=item * C<$key> - Determines what should be throttled (only B<ip> and B<email> are allowed)

=item * C<$identifier> - The subject of throttling

=back

Returns undef

=cut

sub _increment_failed_attempt {
    my ($key, $identifier) = @_;

    my $redis               = BOM::Config::Redis::redis_auth_write();
    my $failure_counter_key = join '::', (FAILURE_COUNTER_KEY, $key, $identifier);
    my $backoff_key         = join '::', (BACKOFF_KEY,         $key, $identifier);

    my $count = $redis->incr($failure_counter_key);
    my $round = _get_round($count);

    my $round_attempts = $count % ROUND_WINDOW;
    $round_attempts = $round_attempts == 0 ? ROUND_WINDOW : $round_attempts;    # if no remainder, assume ROUND_WINDOW

    my $is_first_round  = ($round <= 1 && $round_attempts >= FIRST_ROUND_TRIGGER_COUNT);
    my $is_second_round = ($round > 1  && $round_attempts >= SUBSEQ_ROUND_TRIGGER_COUNT);
    my $is_subseq_round = $round > 2;

    if ($is_first_round || $is_second_round || $is_subseq_round) {
        my ($min, $max);

        if ($is_first_round) {
            $min = FIRST_ROUND_MIN_BACKOFF;
            $max = FIRST_ROUND_MAX_BACKOFF;
        } else {
            $min = SUBSEQ_ROUND_MIN_BACKOFF;
            $max = SUBSEQ_ROUND_MAX_BACKOFF;
        }

        my $backoff = Algorithm::Backoff->new(
            min      => $min,
            max      => $max,
            attempts => $round_attempts,
        );

        my $next_backoff = $backoff->next_value;

        $redis->set($backoff_key, $next_backoff, EX => $next_backoff);
    }

    # save counter until next day
    $redis->expire($failure_counter_key, COUNTER_TTL);

    return undef;
}

=head2 inspect_failed_login_attempts

Checks whether is the current login attempt valid or should get throttled

=over 4

=item * C<$ip> - (optional) Client ip

=item * C<$email> - (optional) Client email

=back

Throws a hash contains error code.

Returns undef if no error found.

=cut

sub inspect_failed_login_attempts {
    my %args = @_;

    my $ip    = $args{ip};
    my $email = $args{email};

    my $redis = BOM::Config::Redis::redis_auth();

    _yield_blocked_authorize_error() if $ip and $redis->get(join '::', (BACKOFF_KEY, 'ip', $ip));

    if ($email) {
        _yield_blocked_authorize_error() if $redis->get(join '::', (BACKOFF_KEY, 'email', $email));

        my $user = BOM::User->new(email => $email);
        _yield_blocked_authorize_error() if $user and $redis->get(join '::', (BACKOFF_KEY, 'binary_user_id', $user->id));
    }

    return undef;
}

=head2 _get_round

Calculate round of attempts by ROUND_WINDOW

=cut

sub _get_round {
    my $failure_count = shift;

    return POSIX::ceil($failure_count / ROUND_WINDOW);
}

=head2 _yield_blocked_authorize_error

Throw error and submit stats

=cut

sub _yield_blocked_authorize_error {
    stats_inc('login.authorizer.block.hit');

    die +{code => 'SUSPICIOUS_BLOCKED'};
}

1;
