package BOM::User::Record::Payment;

use strict;
use warnings;

use BOM::Config::Redis;
use Date::Utility;
use Digest::SHA qw/sha256_hex/;
use List::Util qw/first max/;

use constant LIFETIME_IN_DAYS           => 90;
use constant LIFETIME_IN_SECONDS        => LIFETIME_IN_DAYS * 24 * 60 * 60;
use constant PAYMENT_KEY_PREFIX         => 'PAYMENT_RECORD';
use constant PAYMENT_KEY_SEPARATOR      => '::';
use constant PAYMENT_KEY_USER_ID_PREFIX => 'UID';

=head2 new

Construct the object

Takes the following arguments as named parameters

=over 4

=item * C<payment_processor> - processor used for the payment to be recorded

=item * C<payment_method> - payment method used, for example VISA

=item * C<payment_type> - type of payment, for example CreditCard

=item * C<user_id> - binary/deriv user id

=item * C<account_identifier> - account identifier user, for example account number, card number

=back

Returns a bless reference object

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        payment_processor  => $args{payment_processor},
        payment_method     => $args{payment_method},
        payment_type       => $args{payment_type},
        user_id            => $args{user_id},
        account_identifier => $args{account_identifier},
    }, $class;
}

=head2 payment_processor

    $obj->payment_processor();

Returns the payment processor passed in the constructor

=cut

sub payment_processor : method { shift->{payment_processor} // '' }

=head2 payment_method

    $obj->payment_method();

Returns the payment method passed in the contructor

=cut

sub payment_method : method { shift->{payment_method} // '' }

=head2 payment_type

    $obj->payment_type();

Returns the payment type passed in the constructor

=cut

sub payment_type : method { shift->{payment_type} // '' }

=head2 user_id

    $obj->payment_method();

Returns the binary user id passed in the constructor

=cut

sub user_id : method { shift->{user_id} // '' }

=head2 account_identifier

    $obj->account_identifier();

Returns the sha256 hash of the account identifier passed in the constructor if present, 0 otherwise

=cut

sub account_identifier : method {
    my $self = shift;

    return 0 unless $self->{account_identifier};

    return sha256_hex($self->{account_identifier});
}

=head2 storage_key

    $obj->storage_key();

Returns the key used to identify this payment in the underlying storage engine if it's possible to build it, 0 otherwise.

=cut

sub storage_key : method {
    my $self = shift;

    return _build_storage_key(user_id => $self->user_id());
}

=head2 save

    $obj->save();

Saves the hashed account identifier on redis

=cut

sub save : method {
    my $self = shift;

    return 0 unless $self->account_identifier();

    # we are recording only credit card payments
    return 0 unless $self->payment_type() eq 'CreditCard';

    my $storage_key = $self->storage_key();
    return 0 unless $storage_key;

    my $redis = _get_redis();
    $redis->multi;
    $redis->pfadd($storage_key, $self->account_identifier());
    # we set the expiry of the whole key
    # we extend expiry whenever the same key is updated
    $redis->expire($storage_key, LIFETIME_IN_SECONDS);
    $redis->exec;

    return 1;
}

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

    die 'Payment record required period length is greater than our storage lifetime of ' . LIFETIME_IN_DAYS . ' days.'
        if $args{period} > LIFETIME_IN_DAYS;

    return 0 unless $self->user_id();

    return _get_redis()->pfcount(
        @{
            _get_keys_for_time_period(
                user_id => $self->user_id(),
                period  => $args{period},
            )});
}

=head2 _get_redis

Returns the connection object to the payments redis instance

=cut

sub _get_redis {
    return BOM::Config::Redis::redis_payment_write();
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

    my @keys = map { _build_storage_key(user_id => $args{user_id}, days_behind => $_) } (0 .. $time_period - 1);

    return \@keys;
}

=head2 _build_storage_key

Returns the storage key given an user_id for the day of C<days_behind> of the current date when provided, defaults to the key for the current date

=cut

sub _build_storage_key {
    my (%args) = @_;
    return 0 unless my $user_id = $args{user_id};
    my $days_behind = $args{days_behind} // 0;

    return join(
        PAYMENT_KEY_SEPARATOR,         #
        PAYMENT_KEY_PREFIX,            #
        PAYMENT_KEY_USER_ID_PREFIX,    #
        $user_id,                      #
        Date::Utility->new->minus_time_interval($days_behind . 'd')->date_yyyymmdd
    );
}

1;
