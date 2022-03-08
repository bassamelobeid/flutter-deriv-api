package BOM::Event::Actions::MT5;

use strict;
use warnings;

no indirect;

use Log::Any qw($log);

use BOM::Platform::Event::Emitter;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use BOM::User::Utility qw(parse_mt5_group);
use BOM::MT5::User::Async;
use BOM::Config::Redis;
use BOM::Config;
use BOM::Event::Services::Track;
use BOM::Platform::Client::Sanctions;
use BOM::Config::MT5;

use Email::Stuffer;
use YAML::XS;
use Date::Utility;
use Text::CSV;
use List::Util qw(any);
use Path::Tiny;
use JSON::MaybeUTF8 qw/encode_json_utf8/;
use DataDog::DogStatsd::Helper;
use Syntax::Keyword::Try;
use Future::Utils qw(fmap_void);
use Time::Moment;

use Future;
use IO::Async::Loop;
use Net::Async::Redis;

use List::Util qw(sum0);
use HTML::Entities;

use constant DAYS_TO_EXPIRE => 14;
use constant SECONDS_IN_DAY => 86400;

=head2 sync_info

Sync user information to MT5

=over 4

=item * C<data> - data passed in from BOM::Event::Process::process, which is a hashref and have the following keys:

=item * C<loginid> - the login ID for the client to sync data

=item * C<tried_times> - Number of times that this event has been tried

=back

=cut

sub sync_info {
    my $data = shift;
    return undef unless $data->{loginid};
    my $client = BOM::User::Client->new({loginid => $data->{loginid}});
    return 1 if $client->is_virtual;

    my $user = $client->user;
    my @update_operations;

    # If user is disabled MT5 will re-enable it again
    # we have to access MT5 and get the previous user status
    for my $mt_login (sort $user->get_mt5_loginids) {
        my $operation = BOM::MT5::User::Async::get_user($mt_login)->then(
            sub {
                my $mt_user = shift;
                # BOM::MT5::User::Async doesn't ->fail a future on MT5 errors
                return Future->fail($mt_user->{error}) if $mt_user->{error};
                return BOM::MT5::User::Async::update_user({
                        login  => $mt_login,
                        rights => $mt_user->{rights},
                        %{$client->get_mt5_details()}});
            }
        )->then(
            sub {
                my $result = shift;
                return Future->fail($result->{error}) if $result->{error};
                return Future->done($result);
            });
        push @update_operations, $operation;
    }

    return Future->needs_all(@update_operations)->then_done(1)->else(
        sub {
            my $error       = shift;
            my $tried_times = $data->{tried_times} // 0;
            $tried_times++;
            # if that error cannot recoverable
            if ($error =~ /Not found/i) {
                DataDog::DogStatsd::Helper::stats_inc('event.mt5.sync_info.unrecoverable_error');
            } elsif ($tried_times < 5) {
                BOM::Platform::Event::Emitter::emit(
                    'sync_user_to_MT5',
                    {
                        loginid     => $data->{loginid},
                        tried_times => $tried_times
                    });
            }
            # we tried too many times already
            else {
                DataDog::DogStatsd::Helper::stats_inc('event.mt5.sync_info.retried_error');
            }
            return Future->done(0);
        })->get();
}

sub redis_record_mt5_transfer {
    my $input_data = shift;
    my $redis      = BOM::Config::Redis::redis_mt5_user_write();
    my $loginid    = $input_data->{loginid};
    my $mt5_id     = $input_data->{mt5_id};
    my $redis_key  = 'MT5_TRANSFER_' . (uc $input_data->{action}) . '::' . $mt5_id;

    # check if the mt5 id exists in redis
    if ($redis->get($redis_key)) {
        $redis->incrbyfloat($redis_key, $input_data->{amount_in_USD});
    } else {
        $redis->set($redis_key, $input_data->{amount_in_USD});
        # set duration to expire in 14 days
        $redis->expire($redis_key, SECONDS_IN_DAY * DAYS_TO_EXPIRE);
    }

    my $total_amount = $redis->get($redis_key);

    if ($total_amount >= 8000) {
        notifiy_compliance_mt5_over8K({
                loginid      => $loginid,
                mt5_id       => $mt5_id,
                ttl          => $redis->ttl($redis_key),
                action       => $input_data->{action},
                total_amount => sprintf("%.2f", $total_amount)});

        $redis->del($redis_key);
    }

    return 1;
}

sub notifiy_compliance_mt5_over8K {
    # notify compliance about the situation
    my $data                   = shift;
    my $brand                  = request()->brand();
    my $system_email           = $brand->emails('system');
    my $compliance_alert_email = $brand->emails('compliance_alert');

    my $seconds_passed_since_start = (SECONDS_IN_DAY * DAYS_TO_EXPIRE) - $data->{ttl};
    my $start_time_epoch           = (Date::Utility->new()->epoch()) - $seconds_passed_since_start;
    $data->{start_date} = Date::Utility->new($start_time_epoch)->datetime();
    $data->{end_date}   = Date::Utility->new()->datetime();

    my $email_subject = 'VN - International currency transfers reporting obligation';

    my $tt = Template->new(ABSOLUTE => 1);
    $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/mt5_8k.html.tt', $data, \my $html);
    if ($tt->error) {
        $log->warn("Template error " . $tt->error);
        return {status_code => 0};
    }

    my $email_status = Email::Stuffer->from($system_email)->to($compliance_alert_email)->subject($email_subject)->html_body($html)->send();
    unless ($email_status) {
        $log->warn('failed to send email.');
        return {status_code => 0};
    }

    return 1;
}

=head2 new_mt5_signup

This stores the binary_user_id and the timestamp when an unauthenticated CR-client opens a
financial MT5 account. It also sends the user an email to remind them to authenticate, if they
have not

=cut

sub new_mt5_signup {
    my $data   = shift;
    my $client = BOM::User::Client->new({loginid => $data->{loginid}});
    return unless $client;

    my $id = $data->{mt5_login_id} or die 'mt5 loginid is required';

    my $cache_key  = "MT5_USER_GROUP::" . $id;
    my $group      = BOM::Config::Redis::redis_mt5_user()->hmget($cache_key, 'group');
    my $hex_rights = BOM::Config::mt5_user_rights()->{'rights'};

    my %known_rights = map { $_ => hex $hex_rights->{$_} } keys %$hex_rights;

    if ($group->[0]) {
        my $status = BOM::Config::Redis::redis_mt5_user()->hmget($cache_key, 'rights');

        my %rights;

        # This should now have the following keys set:
        # api,enabled,expert,password,reports,trailing
        # Example: status (483 => 1E3)
        $rights{$_} = 1 for grep { $status->[0] & $known_rights{$_} } keys %known_rights;

    } else {
        # ... and if we don't, queue up the request. This may lead to a few duplicates
        # in the queue - that's fine, we check each one to see if it's already
        # been processed.
        BOM::Config::Redis::redis_mt5_user_write()->lpush('MT5_USER_GROUP_PENDING', join(':', $id, time));
    }

    my $group_details   = parse_mt5_group($data->{mt5_group});
    my $company_actions = LandingCompany::Registry->new->get($group_details->{landing_company_short})->actions // {};
    if ($group_details->{account_type} ne 'demo' && any { $_ eq 'sanctions' } ($company_actions->{signup} // [])->@*) {
        BOM::Platform::Client::Sanctions->new(
            client                        => $client,
            brand                         => request()->brand,
            recheck_authenticated_clients => 1
        )->check(
            comments     => "Triggered by a new MT5 signup - MT5 loginid: $id and MT5 group: $data->{mt5_group}",
            triggered_by => "$id ($data->{mt5_group}) signup",
        );
    }

    try {
        my $mt5_server_geolocation = BOM::Config::MT5->new(group => $data->{mt5_group})->server_geolocation();

        $data->{mt5_server_region}      = $mt5_server_geolocation->{region};
        $data->{mt5_server_location}    = $mt5_server_geolocation->{location};
        $data->{mt5_server_environment} = BOM::Config::MT5->new(group => $data->{mt5_group})->server_environment();
    } catch ($e) {
        $log->errorf('Unable to send email to client for new mt5 account open due to error: %s', $e);
    }

    # Add email params to track signup event
    $data->{client_first_name} = $client->first_name;
    # Frontend-ish label (Synthetic, Financial, Financial STP)
    my $type_label = $group_details->{market_type};
    $type_label .= '_stp' if $group_details->{sub_account_type} eq 'stp';
    $data->{type_label}     = ucfirst $type_label;                     # Frontend-ish label (Synthetic, Financial, Financial STP)
    $data->{mt5_integer_id} = $id =~ s/${\BOM::User->MT5_REGEX}//r;    # This one is just the numeric ID

    my $brand            = request()->brand;
    my %track_properties = (
        %$data,
        client            => $client,
        mt5_dashboard_url => $brand->mt5_dashboard_url({language => request->language}),
        live_chat_url     => $brand->live_chat_url({language => request->language}),
    );
    $track_properties{mt5_loginid} = delete $track_properties{mt5_login_id};
    return BOM::Event::Services::Track::new_mt5_signup(\%track_properties);
}

=head2 mt5_password_changed

It is triggered for each B<mt5_password_changed> event emitted.
It can be called with the following parameters:

=over

=item * C<args> - required. Including the login Id of the user with required properties.

=back

=cut

sub mt5_password_changed {
    my ($args) = @_;

    die 'mt5 loginid is required' unless $args->{mt5_loginid};

    return BOM::Event::Services::Track::mt5_password_changed($args);
}

=head2 mt5_inactive_notification

Sends emails to a user notifiying them about their inactive mt5 accounts before they're closed.
Takes the following named parameters

=over 4

=item * C<email> - user's  email address

=item * C<name> - user's name

=item * C<accounts> - user's inactive mt5 accounts grouped by days remaining to their closure, for example:

{
   7 => [{
             loginid => '1234',
             account_type => 'real gaming',
        },
        ...
    ],
    14 => [{
             loginid => '2345',
             account_type => 'demo financial',
        },
        ...
     ]
}

=back

=cut

sub mt5_inactive_notification {
    my $args = shift;

    my $user    = eval { BOM::User->new(email => $args->{email}) } or die 'Invalid email address';
    my $loginid = eval { [$user->bom_loginids()]->[0] }            or die "User $args->{email} doesn't have any accounts";

    my $now   = Time::Moment->now();
    my $today = Time::Moment->new(
        year  => $now->year,
        month => $now->month,
        day   => $now->day_of_month
    );

    my $futures = fmap_void {
        BOM::Event::Services::Track::mt5_inactive_notification({
            loginid      => $loginid,
            email        => $args->{email},
            name         => $args->{name},
            accounts     => $args->{accounts}->{$_},
            closure_date => $today->plus_days($_)->epoch,
        });
    }
    foreach => [sort { $a <=> $b } keys $args->{accounts}->%*];

    return $futures->then(sub { Future->done(1) });
}

=head2 mt5_inactive_account_closed

Sends emails to a user notifiying them about their inactive mt5 accounts before they're closed.
Takes the following named parameters

=over 4

=item * C<email> - user's  email address

=item * C<name> - user's name

=item * C<mt5_accounts> - a list of the archived mt5 accounts with the same email address (binary user).

=back

=cut

sub mt5_inactive_account_closed {
    my $args = shift;

    my $user    = eval { BOM::User->new(email => $args->{email}) } or die 'Invalid email address';
    my $loginid = eval { [$user->bom_loginids()]->[0] }            or die "User $args->{email} doesn't have any accounts";

    return BOM::Event::Services::Track::mt5_inactive_account_closed({
            loginid       => $loginid,
            name          => $args->{mt5_accounts}->[0]->{name},
            mt5_accounts  => $args->{mt5_accounts},
            live_chat_url => request->brand->live_chat_url({language => request->language})});

}

=head2 mt5_inactive_account_closure_report

Sends email to Compliance, Customer Service and Payments team about account closure details

=over 4

=item * C<reports> - account closure reports

=back

=cut

sub mt5_inactive_account_closure_report {
    my $args = shift;

    my $brand = request()->brand;

    return unless $args->{reports} and $args->{reports}->@*;

    my $csv = path('/tmp/report.csv');
    # cleans the file
    $csv->remove if $csv->exists;
    $csv->touch;
    $csv->append("date,mt5_account,mt5_account_currency,mt5_balance,deriv_account,deriv_account_currency,transferred_amount\n");
    foreach my $data ($args->{reports}->@*) {
        my $line = join ',',
            (map { $data->{$_} } qw(date mt5_account mt5_account_currency mt5_balance deriv_account deriv_account_currency transferred_amount));
        $line .= "\n";
        $csv->append($line);
    }

    # it seems weird that it does not support email in array ref
    foreach my $email ('i-payments@deriv.com', $brand->emails('compliance_alert')) {
        BOM::Platform::Email::send_email({
            to         => $email,
            from       => $brand->emails('no-reply'),
            subject    => 'MT5 account closure report',
            message    => ['MT5 account closure report is attached'],
            attachment => [$csv->[0]],
        });
    }
}

1;
