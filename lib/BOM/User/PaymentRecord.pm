package BOM::User::PaymentRecord;

use strict;
use warnings;

use BOM::Config::Redis;
use Date::Utility;
use List::Util qw/first max/;
use Digest::SHA qw/sha256_hex/;

use constant LIFETIME_IN_DAYS           => 90;
use constant SECONDS_IN_A_DAY           => 86400;
use constant LIFETIME_IN_SECONDS        => LIFETIME_IN_DAYS * SECONDS_IN_A_DAY;
use constant PAYMENT_KEY_PREFIX         => 'PAYMENT_RECORD_V2';
use constant PAYMENT_KEY_SEPARATOR      => '::';
use constant PAYMENT_KEY_USER_ID_PREFIX => 'UID';
# Think of this array as an only append structure, we never change the existing elements, we never delete them nor we flip them around.
# Otherwise data corruption and agony!
# pp: payment processor, pm: payment method, pt: payment type, id: payment method identifier
use constant PAYMENT_SERIALIZE_FIELDS => [qw/pp pm pt id/];
use constant PAYMENT_UNDEF_SYMBOL     => '^';

# drop these after legacy key expiration
use constant LEGACY_PAYMENT_KEY_PREFIX => 'PAYMENT_RECORD';
use constant TEMP_PAYMENT_KEY_PREFIX   => 'TEMP_PAYMENT_RECORD';

=head2 new

Construct the object

Takes the following arguments as named parameters

=over 4

=item * C<user_id> - binary/deriv user id

=back

Returns a bless reference object

=cut

sub new {
    my ($class, %args) = @_;

    die 'user_id is mandatory' unless $args{user_id};

    return bless {
        user_id => $args{user_id},
    }, $class;
}

=head2 storage_key

Returns the redis key for the current user id.

=cut

sub storage_key : method {
    my ($self) = @_;

    return join(PAYMENT_KEY_SEPARATOR, PAYMENT_KEY_PREFIX, PAYMENT_KEY_USER_ID_PREFIX, $self->{user_id});
}

=head2 add_payment

Stores the payment as its payload representation into the Redis ZSET.

Takes the following arguments as named parameters

=over 4

=item * C<pp> - payment processor

=item * C<pm> - payment method

=item * C<pt> - payment type

=item * C<id> - client's payment method identifier.

=back

Returns C<1> on success.

=cut

sub add_payment : method {
    my ($self, %args) = @_;

    my $payload     = $self->get_payload(\%args);
    my $storage_key = $self->storage_key();

    my $redis = _get_redis();

    # to avoid clashes with the old implementation we will use a temporary
    # hyperloglog with the current element, merge with the user's hyperloglog and
    # check the cardinality.
    my $pt = $args{pt} // '';
    my $id = $args{id} // '';

    if ($pt eq 'CreditCard') {
        if ($id ne '') {
            $redis->pfadd(TEMP_PAYMENT_KEY_PREFIX . $self->{user_id}, sha256_hex($args{id}));
            $redis->pfmerge(
                TEMP_PAYMENT_KEY_PREFIX . $self->{user_id},
                @{
                    _get_keys_for_time_period(
                        payment_type => 'CreditCard',
                        user_id      => $self->{user_id},
                        period       => LIFETIME_IN_DAYS
                    )});

            my $current = $self->get_distinct_payment_accounts_for_time_period(
                period       => LIFETIME_IN_DAYS,
                payment_type => 'CreditCard'
            );

            my $addition = $redis->pfcount(TEMP_PAYMENT_KEY_PREFIX . $self->{user_id});
            $redis->del(TEMP_PAYMENT_KEY_PREFIX . $self->{user_id});

            if ($current == $addition) {
                return 0;
            }
        }
    }

    $redis->multi;
    $redis->zadd($storage_key, time, $payload);
    # we set the expiry of the whole key
    # we extend expiry whenever the same key is updated
    # note we will use a cronjob script to trim the zsets and keep the memory tamed
    $redis->expire($storage_key, LIFETIME_IN_SECONDS);
    $redis->exec;

    return 1;
}

=head2 from_payload

Given a payload string, recovers the equivalent hashref structure.

It takes:

=over 4

=item * C<$payload> - the payload as a string

=back

Returns a hashref.

=cut

sub from_payload {
    my (undef, $payload) = @_;

    my %payment;

    @payment{@{+PAYMENT_SERIALIZE_FIELDS}} = map { $_ eq PAYMENT_UNDEF_SYMBOL ? undef : $_ } split(/\|/, $payload);

    return \%payment;
}

=head2 get_payload

Generates the payload for the payment, this is a pipe `|` separated string of each element of the
payment. If one component of the array is undef we will use the `^` symbol to represent it.

It takes the following args:

=over 4

=item * C<pp> - payment processor

=item * C<pm> - payment method

=item * C<pt> - payment type

=item * C<id> - payment method identifier

=back

Returns a pipe separated string that represents the current payment.

=cut

sub get_payload {
    my (undef, $args) = @_;

    return join('|', map { $_ // PAYMENT_UNDEF_SYMBOL } @$args{@{+PAYMENT_SERIALIZE_FIELDS}});
}

=head2 get_payments

Returns the subset of payments made in the defined period as hashrefs.

It takes:

=over 4

=item * C<$period> - Number of days to get the data for

=back

Returns an arrayref of payments hashrefs.

=cut

sub get_payments : method {
    my ($self, $period) = @_;

    my $payments = $self->get_raw_payments($period);

    return [map { $self->from_payload($_) } $payments->@*];
}

=head2 get_raw_payments

Returns the subset of payments made in the defined period as strings.

It takes:

=over 4

=item * C<$period> - Number of days to get the data for

=back

Returns an arrayref of payments strings.

=cut

sub get_raw_payments {
    my ($self, $period) = @_;

    return [] unless $period;

    return [] if $period > LIFETIME_IN_DAYS;

    my $storage_key = $self->storage_key();

    my $lower_bound = time - SECONDS_IN_A_DAY * $period;

    return _get_redis()->zrangebyscore($storage_key, $lower_bound, '+Inf');
}

=head2 filter_payments

Given a payment object and arrayref of payments strings, filter out those that do not match.

Note that a non existant key will be treated as wildcard instead of undef.

It takes:

=over 4

=item C<$payment> - a payment hashref

=item C<$resulset> - the payments string arrayref.

=back

Returns a subset o C<$resultset> with only those payments that had a match.

=cut

sub filter_payments {
    my (undef, $payment, $resultset) = @_;
    my $regex = [];

    for (qw/pp pm pt id/) {
        my $re_comp;

        if (exists $payment->{$_}) {
            if (defined $payment->{$_}) {
                my $value = $payment->{$_};
                $re_comp = "\Q$value\E";
            } else {
                $re_comp = "\Q^\E";
            }
        } else {
            $re_comp = '(.*)?';
        }

        push $regex->@*, $re_comp;
    }

    my $regex_str = join "\Q|\E", $regex->@*;

    return [grep { $_ =~ /^$regex_str/ } $resultset->@*];
}

=head2 group_by_id

Given a resultset, groups them by id.

It takes:

=over 4

=item C<$resulset> - the payments string arrayref.

=back

Returns a subset of C<$resultset> with grouped payments by id.

=cut

sub group_by_id {
    my ($self, $resultset) = @_;

    my $group = {};

    for my $payload ($resultset->@*) {
        my $payment = $self->from_payload($payload);
        my $id      = $payment->{id};
        next if defined $id and exists $group->{$id};
        $group->{$id} = $payload if defined $id;
    }

    return [values $group->%*];
}

=head2 trimmer

Trims all the payment records zset into its LIFETIME_IN_DAYS boundary.

The scan command was used, note this command ensure all the matched keys will get
iterated over a full sweep of the cursor, the cursor will return to 0 when the sweep is finished.

Note this is not a class method.

=cut

sub trimmer {
    my $upper_bound = time - LIFETIME_IN_SECONDS;
    my $redis       = _get_redis();
    my $cursor      = 0;
    my $keys;

    do {
        ($cursor, $keys) = $redis->scan($cursor, 'MATCH', +PAYMENT_KEY_PREFIX . '*')->@*;

        $redis->zremrangebyscore($_, '-Inf', $upper_bound) for $keys->@*;

    } while ($cursor > 0);

    return 1;
}

=head2 _get_redis

Returns the connection object to the payments redis instance

=cut

sub _get_redis {
    return BOM::Config::Redis::redis_payment_write();
}

=head1 DEPRECATED

From this points the functions defined are deprecated and we must consider removing them once
the legacy redis keys are all expired on production servers.

=head2 get_distinct_payment_accounts_for_time_period

    $obj->get_distinct_payment_accounts_for_time_period(period => 30, ...);

Returns the count of unique account identifiers for a given period of time, period is passed in as days

Takes the following as named parameters

=over 4

=item * C<period>

Number of days to get the data for

=back

=cut

sub get_distinct_payment_accounts_for_time_period : method {
    my ($self, %args) = @_;

    return 0 unless $args{period};

    return 0 unless $args{payment_type};

    die 'Payment record required period length is greater than our storage lifetime of ' . LIFETIME_IN_DAYS . ' days.'
        if $args{period} > LIFETIME_IN_DAYS;

    return 0 unless $self->{user_id};

    return _get_redis()->pfcount(
        @{
            _get_keys_for_time_period(
                payment_type => $args{payment_type},
                user_id      => $self->{user_id},
                period       => $args{period},
            )});
}

=head2 _get_keys_for_time_period

Returns an array containing all keys

Takes the following as named parameters

=over 4

=item * C<period>

Number of days to get the data for

=item * C<user_id>

The id of the user to fetch the keys for

=back

=cut

sub _get_keys_for_time_period {
    my (%args) = @_;

    my $time_period = max($args{period} // 1, 1);

    my @keys = map { _build_storage_key(payment_type => $args{payment_type}, user_id => $args{user_id}, days_behind => $_) } (0 .. $time_period - 1);

    return \@keys;
}

=head2 _build_storage_key

Returns the storage key given an user_id for the day of C<days_behind> of the current date when provided, defaults to the key for the current date

=cut

sub _build_storage_key {
    my (%args) = @_;
    return 0 unless my $user_id      = $args{user_id};
    return 0 unless my $payment_type = $args{payment_type};
    my $days_behind = $args{days_behind} // 0;

    my @key_parts = (
        LEGACY_PAYMENT_KEY_PREFIX, PAYMENT_KEY_USER_ID_PREFIX, $user_id, $payment_type,
        Date::Utility->new->minus_time_interval($days_behind . 'd')->date_yyyymmdd
    );

    # this package was designed only for CreditCard, the business logic has changed
    # to generalize the payment type, we need to map the $payment_type accordingly
    # in order to make it backcompat

    if ($payment_type eq 'CreditCard') {
        my $date = pop @key_parts;
        pop @key_parts;
        push @key_parts, $date;
    }

    return join(PAYMENT_KEY_SEPARATOR, @key_parts);
}

=head2 is_flagged

Takes the following as positional parameter

=over 4

=item * C<name> The name of the flag

=back

=cut

sub is_flagged {
    my ($self, $flag_name) = @_;

    return _get_redis()->get(
        _build_flag_key(
            user_id => $self->{user_id},
            name    => $flag_name
        )) // 0;
}

=head2 _build_flag_key

Takes the following as named parameters

=over 4

=item * C<user_id> The id of the user who made the payment

=item * C<name> The name of the flag

=back

=cut

sub _build_flag_key {
    my %args = @_;

    return join(
        PAYMENT_KEY_SEPARATOR,         #
        PAYMENT_KEY_PREFIX,            #
        PAYMENT_KEY_USER_ID_PREFIX,    #
        $args{user_id},                #
        $args{name});
}

1;
