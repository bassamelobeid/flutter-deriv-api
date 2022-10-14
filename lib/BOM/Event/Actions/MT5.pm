package BOM::Event::Actions::MT5;

use strict;
use warnings;

no indirect;

use Log::Any qw($log);

use BOM::Platform::Event::Emitter;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Email   qw(send_email);
use BOM::User::Client;
use BOM::User::Utility qw(parse_mt5_group);
use BOM::MT5::User::Async;
use BOM::Config::Redis;
use BOM::Config;
use BOM::Event::Services::Track;
use BOM::Platform::Client::Sanctions;
use BOM::Config::MT5;
use Future::AsyncAwait;

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
use WebService::MyAffiliates;
use Scalar::Util;

use LandingCompany::Registry;
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
    my $company_actions = LandingCompany::Registry->by_name($group_details->{landing_company_short})->actions // {};
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
    $type_label .= ' STP' if $group_details->{sub_account_type} eq 'stp';
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

=head2 mt5_change_color

Changes the color field for an mt5 client
Takes the following parameters: 

=over

=item * C<args> - Hash which includes the loginid and the color values, both required.

=back

=cut

async sub mt5_change_color {
    my $args    = shift;
    my $loginid = $args->{loginid};
    my $color   = $args->{color};

    die 'Loginid is required' unless $loginid;
    die 'Color is required'   unless $color;

    my $user_detail = await BOM::MT5::User::Async::get_user($loginid);
    $user_detail->{color} = $color;
    my $updated_user = await BOM::MT5::User::Async::update_user($user_detail);

    die "Could not change client $loginid color to $color" if $updated_user->{color} != ($color == -1 ? 4294967295 : $color);
    die $updated_user->{error}                             if $updated_user->{error};

    my $user           = BOM::User->new(email => $user_detail->{email});
    my $default_client = $user ? $user->get_default_client : undef;

    return BOM::Event::Services::Track::mt5_change_color({
        loginid     => ($default_client ? $default_client->loginid : undef),
        mt5_loginid => $loginid,
        color       => $color
    });
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

=head2 poa_verification_warning

Sends email to the client with the passed loginid to remind that his prove of address is not verified
and that his account will be limited in trading rights in poa_expiry_date

=over 4

=item * C<loginid> - Client loginid

=item * C<poa_expiry_date> - The date that the client will be limited in trading rights in the form of YYYY-MM-DD

=back

=cut

sub poa_verification_warning {
    my $loginid         = shift;
    my $poa_expiry_date = shift;

    die 'Loginid is required'         unless $loginid;
    die 'POA expiry date is required' unless $poa_expiry_date;
    return BOM::Event::Services::Track::poa_verification_warning({loginid => $loginid, poa_expiry_date => $poa_expiry_date});
}

=head2 poa_verification_expired

Sends email to the client with the passed loginid to inform that his poa verification is failed and
he is limited in trading rights

=over 4

=item * C<loginid> - Client loginid

=back

=cut

sub poa_verification_expired {
    my $loginid = shift;

    die 'Loginid is required' unless $loginid;
    return BOM::Event::Services::Track::poa_verification_expired({loginid => $loginid});
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

=head2 link_myaff_token_to_mt5

Function for linking MyAffiliate token to MT5

=over 4

=item * C<client_loginid> - client login

=item * C<client_mt5_login> - client MT5 login

=item * C<myaffiliates_token> - MyAffiliate token

=item * C<server> - server name

=item * C<broker_code> - broker code

=back

=cut

async sub link_myaff_token_to_mt5 {

    my $args = shift;

    my ($client_loginid, $client_mt5_login, $myaffiliates_token, $server) = @{$args}{qw/client_loginid client_mt5_login myaffiliates_token server/};

    my $user_details;

    my $ib_affiliate_id = _get_ib_affiliate_id_from_token($myaffiliates_token);

    my $agent_login = _get_mt5_agent_account_id({
        affiliate_id => $ib_affiliate_id,
        loginid      => $client_loginid,
        server       => $server,
    });

    my $agent_id = 'MTR' . $agent_login;

    try {
        $user_details = await BOM::MT5::User::Async::get_user($client_mt5_login);
    } catch ($e) {
        if ($e->{error} =~ m/Not found/i) {
            $log->errorf("An error occured while retrieving user '%s' from MT5 : %s", $client_mt5_login, $e);
            return 1;
        }

        die $e;
    }

    die "Could not get details for client $client_mt5_login while linking to affiliate $ib_affiliate_id" unless $user_details;

    # MT5 has problem updating the color to None (4278190080) , let's remove the color from user update
    delete $user_details->{color};

    # Assign the affiliate token in the MT5 API
    my $updated_user = await BOM::MT5::User::Async::update_user({
        %{$user_details},
        login => $client_mt5_login,
        agent => $agent_id
    });

    die "Could not link client $client_mt5_login to agent $ib_affiliate_id" unless $updated_user;
    die $updated_user->{error} if $updated_user->{error};

    $log->debugf("Successfully linked client %s to affiliate %s", $client_mt5_login, $ib_affiliate_id);
}

=head2 _get_ib_affiliate_id_from_token

Get IB's affiliate ID based on MyAffiliate token

=over 4

=item * C<$token> string that contains a valid MyAffiliate token

=back

Returns a C<$ib_affiliate_id> an integer representing MyAffiliate ID to link to an IB

=cut

sub _get_ib_affiliate_id_from_token {
    my ($token) = @_;

    my $ib_affiliate_id;
    my $myaffiliates_config = BOM::Config::third_party()->{myaffiliates};

    my $aff = WebService::MyAffiliates->new(
        user    => $myaffiliates_config->{user},
        pass    => $myaffiliates_config->{pass},
        host    => $myaffiliates_config->{host},
        timeout => 10
    );

    die "Unable to create MyAffiliate object to parse token $token" unless $aff;

    my $myaffiliate_id = $aff->get_affiliate_id_from_token($token);

    die "Unable to parse MyAffiliate token $token" unless $myaffiliate_id;

    die "Unable to map token $token to an affiliate ($myaffiliate_id)" if $myaffiliate_id !~ /^\d+$/;

    my $affiliate_user = $aff->get_user($myaffiliate_id);

    die "Unable to get MyAffiliate user $myaffiliate_id from token $token" unless $affiliate_user;

    if (ref $affiliate_user->{USER_VARIABLES}{VARIABLE} ne 'ARRAY') {
        die "User variable is not defined for $myaffiliate_id from token $token";
    }

    my @mt5_custom_var =
        map { $_->{VALUE} =~ s/\s//rg; } grep { $_->{NAME} =~ s/\s//rg eq 'mt5_account' } $affiliate_user->{USER_VARIABLES}{VARIABLE}->@*;
    $ib_affiliate_id = $myaffiliate_id if $mt5_custom_var[0];

    # If we are receiving anything other than the affiliate id then the token was not parsed successfully
    die "Unable to get Affiliate ID for $myaffiliate_id" unless $ib_affiliate_id;

    die "Affiliate ID is not a number, getting '$ib_affiliate_id' instead"
        if ($ib_affiliate_id && !Scalar::Util::looks_like_number($ib_affiliate_id));

    return $ib_affiliate_id;
}

=head2 _get_mt5_agent_account_id

_get_mt5_agent_account_id({account_type => 'real', ...});

Retrieve agent's MT5 account ID on the target server

=over 4

=item * C<$params> - hashref with the following keys

=item * C<$user> - with the value of L<BOM::User> instance

=item * C<$account_type> - with the value of demo/real

=item * C<$country> - with value of country 2 characters code, e.g. ID

=item * C<$affiliate_id> - an integer representing MyAffiliate id as the output of _get_ib_affiliate_id_from_token

=item * C<$market> - market type such financial/synthetic

=back

Return C<$agent_id> an integer representing agent's MT5 account ID

=cut

sub _get_mt5_agent_account_id {
    my $args = shift;

    my ($loginid, $affiliate_id, $server) =
        @{$args}{qw(loginid affiliate_id server)};

    my $client = BOM::User::Client->new({loginid => $loginid});

    my ($agent_id) = $client->user->dbic->run(
        fixup => sub {
            $_->selectrow_array("SELECT * FROM mt5.get_agent_id(?, ?)", undef, $affiliate_id, $server);
        });

    unless ($agent_id) {
        DataDog::DogStatsd::Helper::stats_inc('myaffiliates.mt5.failure.no_info');
        die "Could not get MT5 agent account ID for affiliate " . $affiliate_id . " while linking to client " . $loginid;
    }

    return $agent_id;
}

=head2 mt5_archived_account_reset_trading_password

Reset trading_password on Deriv account once MT 5 account is archived on the condition that the client does not have any active MT5 accounts after archiving. 

=over 4

=item * C<email> - user's  email address

=back

=head2 Comment

There is a possibility race condition where by if the user creates an MT5 account after the check has completed
but before the password reset has been executed, would the password reset in that situation be valid or acceptable?

Couple of things to note about the MT5 archival script

    1. The script runs once a day and it archives the user's MT5 accounts with inactivity duration of 30 days (at the time of this writing, the default is 30).
    2. The trading password reset function will only be triggered if the user currently does not have any active MT5 accounts when the archival script is being executed.

The probability of users creating a new MT5 account after the archival process is executed is quite low.

=cut

sub mt5_archived_account_reset_trading_password {
    my $args = shift;

    my $user = eval { BOM::User->new(email => $args->{email}) } or die 'Invalid email address';

    $log->debugf("mt5_archived_account_reset_trading_password [%s]: Attemtpting reset trading password for user [%s]",
        Time::Moment->now, $args->{email});

    my @mt5_loginids = $user->get_mt5_loginids;    # Includes archived accounts

    my (@active_mt5_accounts);

    my @mt5_users_get = map { BOM::MT5::User::Async::get_user($_)->set_label($_) } @mt5_loginids;
    Future->wait_all(@mt5_users_get)->then(
        sub {
            for my $result (@_) { push @active_mt5_accounts, $result->label if !$result->is_failed; }    # Filter out archived accounts
        })->get;

    try {
        if (scalar(@active_mt5_accounts) == 0) {

            my $user_db = BOM::Database::UserDB::rose_db();
            $user_db->dbic->run(
                fixup => sub {
                    $_->do('SELECT users.reset_trading_password(?)', undef, $user->{id});
                });

            $log->debugf("mt5_archived_account_reset_trading_password [%s]: Auto reset trading password for user [%s]",
                Time::Moment->now, $args->{email});
        } else {
            $log->debugf(
                "mt5_archived_account_reset_trading_password [%s]: User [%s] currently has %s account(s) that is active. No reset trading password action taken.",
                Time::Moment->now, $args->{email}, scalar(@active_mt5_accounts));
        }
    } catch ($e) {
        $log->errorf("mt5_archived_account_reset_trading_password [%s]: Unable to reset password due to error: %s", Time::Moment->now, $e);
    }
}

=head2 update_loginid_status

Update the loginid.status in users DB.

=over 4

=item * C<loginid> - user's login id

=item * C<binary_user_id> - user's binary user id

=item * C<status_code> - status code. It follows the users.loginid_status enum. Can pass undef value to set the loginid.status column to NULL

=back

=cut

sub update_loginid_status {
    my $args = shift;

    die 'Must provide loginid'        unless $args->{loginid};
    die 'Must provide binary_user_id' unless $args->{binary_user_id};

    try {
        my $user_db = BOM::Database::UserDB::rose_db();

        $user_db->dbic->run(
            fixup => sub {
                $_->do('SELECT users.update_loginid_status(?,?,?)', undef, $args->{loginid}, $args->{binary_user_id}, $args->{status_code});
            });

    } catch ($e) {
        $log->errorf("update_loginid_status [%s]: Unable to set loginid.status due to error: %s", Time::Moment->now, $e);
    }
}

1;
