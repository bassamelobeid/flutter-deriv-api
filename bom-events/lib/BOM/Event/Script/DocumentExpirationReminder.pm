package BOM::Event::Script::DocumentExpirationReminder;

=head1 NAME

BOM::Event::Script::DocumentExpirationReminder - A cron job script that reminds about soon to be expired documents

=head1 DESCRIPTION

Provides a testable suite of functions with the purpose of fetching soon to be expired clients.
And notified them through some customer.io email send.

=cut

use strict;
use warnings;

use BOM::Platform::Event::Emitter;
use BOM::Database::UserDB;
use Future::AsyncAwait;
use BOM::User::Client::AuthenticationDocuments;
use IO::Async::Loop;
use BOM::Event::Services;
use BOM::Platform::Context qw(request);
use BOM::Config::MT5;
use List::Util qw(uniq);
use Date::Utility;
use BOM::User;
use BOM::User::Client;
use UUID::Tiny;
use Net::Domain qw( hostname );

use constant DOCUMENT_EXPIRATION_REMINDER_LOCK       => 'DOCUMENT::EXPIRATION::REMINDER::';
use constant DOCUMENT_EXPIRATION_REMINDER_TTL        => 86400 * 30;                           # don't bother the client for another 30 DAYS
use constant DOCUMENT_EXPIRATION_REMINDER_LOOK_AHEAD => 90;                                   # 3 months in advance
use constant DOCUMENT_EXPIRATION_LOOK_BACK_DAYS      => 15;

=head2 new

Constructor for this package

=cut

sub new {
    return bless +{}, 'BOM::Event::Script::DocumentExpirationReminder';
}

=head2 run

Runs pending checks again.

=cut

async sub run {
    my ($self) = @_;

    my $service_contexts = {
        user => {
            correlation_id => UUID::Tiny::create_UUID_as_string(UUID::Tiny::UUID_V4),
            auth_token     => "Unused but required to be present",
            environment    => hostname() . ' BOM::Event::Script::DocumentExpirationReminder ' . $$,
        },
    };

    await $self->expiring_today($service_contexts);
    await $self->soon_to_be_expired($service_contexts);
}

=head2 expiring_today

Process the notification for those clients whose POI are expiring today

=cut

async sub expiring_today {
    my ($self, $service_contexts) = @_;

    my $mt5_config = BOM::Config::MT5->new;
    my $offset     = 0;
    my $list;

    # expiration date is now
    my $expiration = Date::Utility->new;

    #lookback to sandwhich with
    my $lookback = Date::Utility->new->minus_time_interval(+DOCUMENT_EXPIRATION_LOOK_BACK_DAYS . 'd');

    # fetch those users who have a mt5 regulated account
    my $groups = [uniq map { $mt5_config->available_groups({company => $_, server_type => 'real'}, 1) } qw/bvi labuan vanuatu/];

    do {
        my $last;

        $list = $self->fetch_expiring_at($groups, $expiration, $lookback) // [];

        $offset += scalar $list->@*;

        for my $record ($list->@*) {
            await $self->notify_expiring_today($record, $service_contexts);

            $last = $record;
        }

        # in order to properly establish the pagination we need to
        # get the lowest expiration date and subtract 1 day from it,
        # since the query returns tied records, is guaranteed to not
        # get this into an infinite loop and since the list is ordered by
        # expiration date descendent, the last item fetched is guaranteed
        # to have the lowest expiration date

        $expiration = Date::Utility->new($last->{expiration_date})->minus_time_interval('1d');

    } while (scalar $list->@*);
}

=head2 soon_to_be_expired

Process the soon to be expired queue.

=cut

async sub soon_to_be_expired {
    my ($self, $service_contexts) = @_;

    my $mt5_config = BOM::Config::MT5->new;
    my $offset     = 0;
    my $list;

    # expiration date is now + the look ahead
    my $expiration = Date::Utility->new->plus_time_interval(+DOCUMENT_EXPIRATION_REMINDER_LOOK_AHEAD . 'd');

    #lookback to sandwhich with
    my $lookback = Date::Utility->new->plus_time_interval(+DOCUMENT_EXPIRATION_REMINDER_LOOK_AHEAD . 'd')
        ->minus_time_interval(+DOCUMENT_EXPIRATION_LOOK_BACK_DAYS . 'd');

    # fetch those users who have a mt5 regulated account
    my $groups = [uniq map { $mt5_config->available_groups({company => $_, server_type => 'real'}, 1) } qw/bvi labuan vanuatu/];

    do {
        my $last;

        $list = $self->fetch_expiring_at($groups, $expiration, $lookback) // [];

        $offset += scalar $list->@*;

        for my $record ($list->@*) {
            await $self->notify_soon_to_be_expired({
                    $record->%*,
                    expiration_date => $expiration,
                },
                $service_contexts
            );
            $last = $record;
        }

        # in order to properly establish the pagination we need to
        # get the lowest expiration date and subtract 1 day from it,
        # since the query returns tied records, is guaranteed to not
        # get this into an infinite loop and since the list is ordered by
        # expiration date descendent, the last item fetched is guaranteed
        # to have the lowest expiration date

        $expiration = Date::Utility->new($last->{expiration_date})->minus_time_interval('1d');
    } while (scalar $list->@*);
}

=head2 notify_expiring_today

Sends a track event for clients whose POI documents are expiring today.

It takes the following as hashref:

=over 4

=item * C<binary_user_id> - the user id to be notified

=back

Returns C<undef>

=cut

async sub notify_expiring_today {
    my ($self, $record, $service_contexts) = @_;

    my $user = BOM::User->new(id => $record->{binary_user_id});
    return undef unless $user;

    my $client = $user->get_default_client();
    return undef unless $client;

    my $user_data = BOM::Service::user(
        context    => $service_contexts->{user},
        command    => 'get_attributes',
        user_id    => $record->{binary_user_id},
        attributes => [qw(email)],
    );
    die undef unless ($user_data->{status} eq 'ok');

    return undef if await $self->notify_locked($record);

    $self->update_notified_at($record->{binary_user_id});

    BOM::Platform::Event::Emitter::emit(
        'document_expiring_today',
        {
            loginid    => $client->loginid,
            properties => {
                authentication_url => request->brand->authentication_url,
                live_chat_url      => request->brand->live_chat_url,
                email              => $user_data->{attributes}{email},
            }});

    return undef;
}

=head2 update_notified_at

Update the last notified date of the given user id.

=cut

sub update_notified_at {
    my ($self, $user_id) = @_;

    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'select * from users.poi_expiration_notified_at(?::BIGINT, ?::DATE)',
                {Slice => {}},
                $user_id, Date::Utility->new->date_yyyymmdd
            );
        });
}

=head2 notify_soon_to_be_expired

Sends a track event for the soon to be expired client.

It takes the following as hashref:

=over 4

=item * C<binary_user_id> - the user id to be notified

=item * C<expiration_date> - the date to be expired at, must be a L<Date::Utility> instance

=back

Returns C<undef>

=cut

async sub notify_soon_to_be_expired {
    my ($self, $record, $service_contexts) = @_;

    my $user = BOM::User->new(id => $record->{binary_user_id});
    return undef unless $user;

    my $client = $user->get_default_client();
    return undef unless $client;

    my $user_data = BOM::Service::user(
        context    => $service_contexts->{user},
        command    => 'get_attributes',
        user_id    => $record->{binary_user_id},
        attributes => [qw(email)],
    );
    die undef unless ($user_data->{status} eq 'ok');

    return undef if await $self->notify_locked($record);

    $self->update_notified_at($record->{binary_user_id});

    BOM::Platform::Event::Emitter::emit(
        'document_expiring_soon',
        {
            loginid    => $client->loginid,
            properties => {
                expiration_date    => $record->{expiration_date}->epoch,
                authentication_url => request->brand->authentication_url,
                live_chat_url      => request->brand->live_chat_url,
                email              => $user_data->{attributes}{email},
            }});

    return undef;
}

=head2 notify_locked

Checks if the user id can be notified or not (could've been locked).

It takes the following as hashref:

=over 4

=item * C<binary_user_id> - the user id to be notified

=back

Returns a boolean scalar.

=cut

async sub notify_locked {
    my ($self, $record) = @_;

    my $acquire_lock =
        await $self->redis->set(DOCUMENT_EXPIRATION_REMINDER_LOCK . $record->{binary_user_id}, 1, 'NX', 'EX', DOCUMENT_EXPIRATION_REMINDER_TTL);

    return !$acquire_lock;
}

=head2 fetch_expiring_at

Grabs from the database a list of user ids whose documents are about to expire,
in a paginated fashion.

Note for pagination you have to sandwich both expiration and lookback dates (inclusive range).

Takes the following:

=over 4

=item * C<$groups> - mt5 groups to narrow down the fetching

=item * C<$expiration> - expiration date to look for L<Date::Utility> instance

=item * C<$lookback> - lower boundary of the paging sandwich L<Date::Utility> instance

=back

Returns and arrayref of user ids.

=cut

sub fetch_expiring_at {
    my ($self, $groups, $expiration, $lookback) = @_;

    return BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'select * from users.get_poi_expiring_at(?::VARCHAR[], ?::DATE, ?::DATE)',
                {Slice => {}},
                $groups, $expiration->date_yyyymmdd,
                $lookback->date_yyyymmdd,
            );
        });
}

=head2 redis

Get the redis instance

=cut

sub redis {
    my ($self) = @_;

    return $self->{redis} if $self->{redis};

    $self->{loop} //= IO::Async::Loop->new;

    $self->{loop}->add(my $services = BOM::Event::Services->new);

    $self->{redis} = $services->redis_events_write();

    return $self->{redis};
}

1;
