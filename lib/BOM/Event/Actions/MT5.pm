package BOM::Event::Actions::MT5;

use strict;
use warnings;

no indirect;

use Log::Any qw($log);

use BOM::Platform::Event::Emitter;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Email   qw(send_email);
use BOM::User;
use BOM::User::Client;
use BOM::User::Utility qw(parse_mt5_group);
use BOM::MT5::User::Async;
use BOM::Config::Redis;
use BOM::Config;
use BOM::Event::Services::Track;
use BOM::Platform::Client::Sanctions;
use BOM::Config::MT5;
use BOM::Rules::Engine;
use BOM::Platform::Context::Request;
use Future::AsyncAwait;

use Email::Stuffer;
use YAML::XS;
use Date::Utility;
use Text::CSV;
use List::Util qw(any all none);
use Path::Tiny;
use JSON::MaybeUTF8 qw/encode_json_utf8/;
use JSON::MaybeXS   qw(decode_json);
use DataDog::DogStatsd::Helper;
use Syntax::Keyword::Try;
use Future::Utils qw(fmap_void try_repeat);
use Time::Moment;
use WebService::MyAffiliates;
use Scalar::Util;
use Data::Dump 'pp';

use LandingCompany::Registry;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Async::Redis;
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Format::Util::Numbers            qw(financialrounding);

use List::Util qw(sum0);
use HTML::Entities;

use constant DAYS_TO_EXPIRE            => 14;
use constant SECONDS_IN_DAY            => 86400;
use constant USER_RIGHT_ENABLED        => 0x0000000000000001;
use constant USER_RIGHT_TRADE_DISABLED => 0x0000000000000004;
use constant COLOR_RED                 => 255;
use constant COLOR_BLACK               => 0;
use constant COLOR_NONE                => -1;

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
    my $group      = $input_data->{group};
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
                group        => $group,
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
        loginid           => $client->loginid,
        mt5_dashboard_url => $brand->mt5_dashboard_url({language => request->language}),
        live_chat_url     => $brand->live_chat_url({language => request->language}),
    );
    $track_properties{mt5_loginid} = delete $track_properties{mt5_login_id};
    return BOM::Platform::Event::Emitter::emit('new_mt5_signup_stored', {%track_properties});
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
    die 'Color is required'   unless defined $color;

    my $user_detail;

    try {
        $user_detail = await BOM::MT5::User::Async::get_user($loginid);
    } catch ($e) {
        if ($e->{code} eq 'NotFound') {
            my $user = BOM::User->new(loginid => $loginid);
            BOM::Platform::Event::Emitter::emit(
                'update_loginid_status',
                {
                    loginid        => $loginid,
                    binary_user_id => $user->id,
                    status_code    => 'archived'
                });
            die "Account $loginid not found among the active accounts, changed the status to archived";
        }

        die pp($e);
    }

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

    if ($ib_affiliate_id) {
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

    # If we are receiving anything other than the affiliate id then the token was not parsed successfully or not IB type.
    unless ($ib_affiliate_id) {
        DataDog::DogStatsd::Helper::stats_inc('myaffiliates.not_ib', {tags => ['myaffiliate_id:' . $myaffiliate_id]});
        return 0;
    }

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

=head2 mt5_deriv_auto_rescind

A script that receive a list of mt5 accounts to perfrom transfer of funds to first available Deriv account, then archive it.
After archival step, notification will be send to email of account holder and a report of process result will be sent.

=over 4

=item * C<mt5_accounts> - Reference of mt5 accounts list

=item * C<$override_status> - A flag to consider skipping disabled account and validate payment check

=back

Return C<$process_end_result> containing full information on processed mt5 accounts, the success and failed cases.

=head2 Comment

This script will not process for mt5 accounts that only have Deriv accounts with unsupported currency regardless of override status.
The process will consider all Deriv accounts, and pick the first available and valid Deriv account to perform the transfer.
Disabled account are considered if override status flag is true, in which it will be used for transfer if all other Deriv account does not meet condition.

=cut

async sub mt5_deriv_auto_rescind {
    my $args                   = shift;
    my @mt5_accounts           = @{delete $args->{mt5_accounts}};
    my $override_status        = delete $args->{override_status};
    my $custom_transfer_amount = delete $args->{custom_transfer_amount};
    my $skip_archive           = delete $args->{skip_archive};
    my $staff_name             = $args->{staff_name} // 'payment';
    my (%mt5_deriv_accounts, %process_mt5_success, %process_mt5_fail);

    return 1 unless (@mt5_accounts);

    foreach my $mt5_account (@mt5_accounts) {
        try {
            my $user = await BOM::MT5::User::Async::get_user($mt5_account);

            unless ($user->{email}) {
                _create_error(\%process_mt5_fail, $mt5_account, 'MT5 Error', 'MT5 Account retrieved without email');
                next;
            }

            if (not defined($mt5_deriv_accounts{$user->{email}})) {
                my $bom_user = BOM::User->new(email => $user->{email});
                unless (defined($bom_user)) {
                    _create_error(\%process_mt5_fail, $mt5_account, 'MT5 Error', 'BOM User Account not found');
                    next;
                }

                my @bom_login_ids = $bom_user->bom_real_loginids();
                unless (@bom_login_ids) {
                    _create_error(\%process_mt5_fail, $mt5_account, 'MT5 Error', 'BOM User Real Loginids not found');
                    next;
                }

                $mt5_deriv_accounts{$user->{email}} = {
                    bom_user               => $bom_user,
                    deriv_accounts         => \@bom_login_ids,
                    disabled_deriv_account => undef
                };
            }

            push $mt5_deriv_accounts{$user->{email}}{mt5_accounts}->@*, $mt5_account;

        } catch ($e) {
            if (defined($e->{error})) {
                _create_error(\%process_mt5_fail, $mt5_account, 'MT5 Error', $e->{error});
            } else {
                _create_error(\%process_mt5_fail, $mt5_account, 'MT5 Error', 'Error getting MT5 data');
            }
        }
    }

    my %group_to_currency;
    foreach my $bom_email (keys %mt5_deriv_accounts) {
        foreach my $mt5_account ($mt5_deriv_accounts{$bom_email}{mt5_accounts}->@*) {
            my $mt5_user = await BOM::MT5::User::Async::get_user($mt5_account);

            my $is_demo                 = $mt5_user->{group} =~ /^demo/ ? 1 : 0;
            my $disabled_account_option = 0;
            if ($is_demo) {
                _create_error(\%process_mt5_fail, $mt5_account, 'MT5 Error', 'Demo Account detected, do nothing');
            } else {
                foreach my $deriv_account_id ($mt5_deriv_accounts{$bom_email}{deriv_accounts}->@*) {
                    my $params = {
                        deriv_account_id       => $deriv_account_id,
                        mt5_prefix_id          => $mt5_account,
                        mt5_user               => $mt5_user,
                        group_to_ccy           => \%group_to_currency,
                        override_status        => $override_status,
                        mt5_deriv_accounts     => \%mt5_deriv_accounts,
                        process_mt5_fail       => \%process_mt5_fail,
                        custom_transfer_amount => $custom_transfer_amount,
                        skip_archive           => $skip_archive,
                        staff_name             => $staff_name,
                    };

                    if ($disabled_account_option) {
                        $params->{deriv_account_id}        = $mt5_deriv_accounts{$bom_email}{disabled_deriv_account};
                        $params->{disabled_account_bypass} = 1;
                    }

                    my $process_result = await _mt5_cr_auto_rescind_process($params);

                    if ($process_result) {
                        last if $custom_transfer_amount and not $process_result->{archived} and not $skip_archive;

                        $process_mt5_success{$bom_email}{bom_user} = $mt5_deriv_accounts{$bom_email}{bom_user}
                            if not defined($process_mt5_success{$bom_email});

                        if ($process_result->{transferred_deriv}) {
                            $process_mt5_success{$bom_email}{$mt5_user->{login}} = {
                                transferred_deriv          => $process_result->{transferred_deriv},
                                transferred_mt5_amount     => $process_result->{transferred_mt5_amount},
                                transferred_mt5_currency   => $process_result->{transferred_mt5_currency},
                                transferred_deriv_amount   => $process_result->{transferred_deriv_amount},
                                transferred_deriv_currency => $process_result->{transferred_deriv_currency}};

                            push $process_mt5_success{$bom_email}{transfer_targets}->@*, $params->{deriv_account_id};
                        }

                        push $process_mt5_success{$bom_email}{mt5_accounts}->@*, $mt5_user;

                        delete $process_mt5_fail{$mt5_user->{login}} if exists($process_mt5_fail{$mt5_user->{login}});

                        last;

                    } else {
                        #Consider disabled account option if failed at last available Deriv account.
                        if (    $override_status
                            and not $disabled_account_option
                            and $mt5_deriv_accounts{$bom_email}{deriv_accounts}[-1] eq $deriv_account_id
                            and defined($mt5_deriv_accounts{$bom_email}{disabled_deriv_account}))
                        {
                            $disabled_account_option = 1;
                            redo;
                        }
                    }
                }
            }
        }
    }

    my $process_end_result = {
        processed_mt5_accounts => \@mt5_accounts,
        success_case           => \%process_mt5_success,
        failed_case            => \%process_mt5_fail,
        skip_archive           => $skip_archive,
    };

    _send_closure_email(\%process_mt5_success) unless $skip_archive;
    _send_mt5_rescind_report($process_end_result);

    return Future->done($process_end_result);
}

=head2 _mt5_cr_auto_rescind_process

Series of check if Deriv and MT5 meet the condition to perform transfer

=over 4

=item * C<$params> - hashref with the following keys

=item * C<$mt5_user> - MT5 account instance obtained from get user call

=item * C<$group_to_ccy> - Contain mapped information on the currency used for corresponding mt5 account group

=item * C<$override_status> - A flag to consider skipping disabled account and validate payment check

=item * C<$mt5_deriv_accounts> - Reference to gathered list of bom user and its mt5 accounts. Used to record disabled account candidate for this function.

=item * C<$process_mt5_fail> - Reference to record which part of the process failed the requirement for auto rescind process

=item * C<$disabled_account_bypass> - A flag to continue on auto rescind process even if Deriv account is a disabled account.

=back

Return C<$params> set of values containing information on the transfer such as currency, amount, source and target account.

=cut

async sub _mt5_cr_auto_rescind_process {
    my $params = shift;
    my (
        $deriv_account_id,       $mt5_prefix_id,      $mt5_user,         $group_to_ccy,
        $override_status,        $mt5_deriv_accounts, $process_mt5_fail, $disabled_account_bypass,
        $custom_transfer_amount, $skip_archive,       $staff_name
        )
        = @{$params}{
        qw/deriv_account_id mt5_prefix_id mt5_user group_to_ccy override_status mt5_deriv_accounts process_mt5_fail disabled_account_bypass custom_transfer_amount skip_archive staff_name/
        };

    $disabled_account_bypass = 0 unless $disabled_account_bypass;
    my $mt5_id = $mt5_user->{login};

    my $deriv_client;
    try {
        $deriv_client = BOM::User::Client->new({loginid => $deriv_account_id});
    } catch ($e) {
        _create_error($process_mt5_fail, $mt5_id, $deriv_account_id, "Error getting Deriv Account");
        return 0;
    }

    unless ($deriv_client) {
        _create_error($process_mt5_fail, $mt5_id, $deriv_account_id, "Deriv Account not found");
        return 0;
    }

    unless ($deriv_client->currency) {
        _create_error($process_mt5_fail, $mt5_id, $deriv_account_id, "Deriv Account currency not found");
        return 0;
    }

    my $currency;
    if (exists $group_to_ccy->{$mt5_user->{group}} and defined $group_to_ccy->{$mt5_user->{group}}) {
        $currency = $group_to_ccy->{$mt5_user->{group}};
    } else {
        my $user_group = await BOM::MT5::User::Async::get_group($mt5_user->{group});
        $currency = uc($user_group->{currency}) if defined($user_group->{currency});
        $group_to_ccy->{$mt5_user->{group}} = $currency;
    }

    unless ($currency) {
        _create_error($process_mt5_fail, $mt5_id, "MT5 Error", "Currency Group not found");
        return 0;
    }

    my $mt5_transfer_amount = $mt5_user->{balance};
    if ($custom_transfer_amount) {
        $custom_transfer_amount = financialrounding('amount', $currency, $custom_transfer_amount);
        $mt5_transfer_amount    = $custom_transfer_amount < $mt5_user->{balance} ? $custom_transfer_amount : $mt5_user->{balance};
    }

    my $transfer_amount =
        $deriv_client->currency ne $currency ? convert_currency($mt5_transfer_amount, $currency, $deriv_client->currency) : $mt5_transfer_amount;

    my $rule_engine = BOM::Rules::Engine->new(client => [$deriv_client]);
    unless ($override_status) {
        try {
            $deriv_client->validate_payment(
                currency    => $deriv_client->currency,
                amount      => $transfer_amount,
                rule_engine => $rule_engine
            );
        } catch ($e) {
            if (ref $e and defined($e->{message_to_client})) {
                _create_error($process_mt5_fail, $mt5_id, $deriv_account_id, $e->{message_to_client});
            } else {
                _create_error($process_mt5_fail, $mt5_id, $deriv_account_id, 'Validate Payment failed');
            }

            return 0;
        }
    }

    try {
        $rule_engine->apply_rules(
            [qw/landing_company.currency_is_allowed/],
            loginid => $deriv_client->loginid,
        );
    } catch ($e) {
        if (ref $e and defined($e->{message_to_client})) {
            _create_error($process_mt5_fail, $mt5_id, $deriv_account_id, $e->{message_to_client});
        } else {
            _create_error($process_mt5_fail, $mt5_id, $deriv_account_id, 'Currency not allowed');
        }

        return 0;
    }

    if ($deriv_client->status->disabled) {
        unless ($override_status) {
            _create_error($process_mt5_fail, $mt5_id, $deriv_account_id, 'Account Disabled');
            return 0;
        }

        $mt5_deriv_accounts->{$mt5_user->{email}}{disabled_deriv_account} = $deriv_account_id
            if !defined($mt5_deriv_accounts->{$mt5_user->{email}}{disabled_deriv_account});

        return 0 unless $disabled_account_bypass;
    }

    my $open_position = await BOM::MT5::User::Async::get_open_positions_count($mt5_id);
    _create_error($process_mt5_fail, $mt5_id, 'MT5 Error', "Detected $open_position->{total} open position") if $open_position->{total};

    my $open_order = await BOM::MT5::User::Async::get_open_orders_count($mt5_id);
    _create_error($process_mt5_fail, $mt5_id, 'MT5 Error', "Detected $open_order->{total} open order") if $open_order->{total};

    return 0 if $open_position->{total} || $open_order->{total};

    my $rescind_transfer_result = await _mt5_cr_auto_rescind_transfer_process({
        mt5_id              => $mt5_id,
        currency            => $currency,
        mt5_user            => $mt5_user,
        deriv_account_id    => $deriv_account_id,
        deriv_client        => $deriv_client,
        transfer_amount     => $transfer_amount,
        process_mt5_fail    => $process_mt5_fail,
        mt5_transfer_amount => $mt5_transfer_amount,
        staff_name          => $staff_name,
    });

    return 0 unless ($rescind_transfer_result);

    my ($transferred_deriv, $transferred_mt5_value, $remaining_balance, $archivable);
    ($transferred_deriv, $transferred_mt5_value) = @{$rescind_transfer_result}{qw/transferred_deriv transferred_mt5_value/}
        if (exists $rescind_transfer_result->{transferred_deriv});
    $archivable        = $rescind_transfer_result->{archivable};
    $remaining_balance = $rescind_transfer_result->{remaining_balance};

    if (not $archivable and not $skip_archive) {
        _create_error($process_mt5_fail, $mt5_id, "MT5 Error", "Archive condition not met. Remaining Balance: ${currency} ${remaining_balance}");
        return 0 unless $custom_transfer_amount and $transferred_deriv;
    }

    my $archived;
    if ($archivable and not $skip_archive) {
        try {
            $archived = await _archive_mt5_account({mt5_prefix_id => $mt5_prefix_id, mt5_user => $mt5_user, bom_user => $deriv_client->user});
        } catch ($e) {
            $log->debug('AutoRescind Archive failed');
        }

        unless ($archived) {
            _create_error($process_mt5_fail, $mt5_id, "MT5 Error", "Archive process failed");
            return 0;
        }
    }

    return {
        transferred_deriv          => $transferred_deriv,
        transferred_mt5_amount     => $transferred_mt5_value,
        transferred_mt5_currency   => $currency,
        transferred_deriv_amount   => $transfer_amount,
        transferred_deriv_currency => $deriv_client->currency,
        $archived ? (archived => 1) : (),
    };
}

=head2 _mt5_cr_auto_rescind_transfer_process

Perform the operation of transferring funds from MT5 account to Deriv account.

=over 4

=item * C<$params> - hashref with the following keys

=item * C<$mt5_id> - MT5 account ID

=item * C<$currency> - Currency type of MT5 account

=item * C<$mt5_user> - MT5 account instance obtained from get user call

=item * C<$deriv_account_id> - Deriv Client Account ID

=item * C<$deriv_client> - Reference to deriv client instance

=item * C<$transfer_amount> - The amount of funds to transfer towards deriv account

=item * C<$process_mt5_fail> - Reference to record which part of the process failed the requirement for auto rescind process

=back

Return C<$params> set of values containing information on the transfer such as transferred_deriv, transferred_mt5_value, and archievable.

=cut

async sub _mt5_cr_auto_rescind_transfer_process {
    my $params = shift;
    my ($mt5_id, $currency, $mt5_user, $deriv_account_id, $deriv_client, $transfer_amount, $process_mt5_fail, $mt5_transfer_amount, $staff_name) =
        @{$params}{qw/mt5_id currency mt5_user deriv_account_id deriv_client transfer_amount process_mt5_fail mt5_transfer_amount staff_name/};

    my $mt5_balance_before = $mt5_user->{balance};
    my $archivable         = 0;
    my $transfer_triggered = 0;
    if ($mt5_balance_before == 0) {
        $archivable = 1;
    } elsif ($mt5_balance_before > 0) {
        my $mt5_balance_change;
        try {
            $mt5_balance_change = await BOM::MT5::User::Async::user_balance_change({
                login        => $mt5_id,
                user_balance => -$mt5_transfer_amount,
                comment      => "Auto transfer to [$deriv_account_id]",
                type         => 'balance'
            });
        } catch ($e) {
            _create_error($process_mt5_fail, $mt5_id, 'MT5 Error',
                'Balance update response failed but may have been updated. Manual check required.');
            return 0;
        }

        try {
            $mt5_user = await BOM::MT5::User::Async::get_user($mt5_id);
            if ($mt5_balance_change->{status} and $mt5_user->{balance} == ($mt5_balance_before - $mt5_transfer_amount)) {
                $transfer_amount = financialrounding('price', $deriv_client->currency, $transfer_amount);
                my ($txn) = $deriv_client->payment_mt5_transfer(
                    currency => $deriv_client->currency,
                    amount   => $transfer_amount,
                    remark   => "Transfer from MT5 account $mt5_id to $deriv_account_id $currency $mt5_transfer_amount to "
                        . $deriv_client->currency
                        . " $transfer_amount",
                    staff  => $staff_name,
                    fees   => 0,
                    source => 1
                );

                my $result = _record_mt5_transfer($deriv_client->db->dbic, $txn->payment_id, $mt5_transfer_amount, $mt5_id, $currency);

                unless ($result) {
                    _create_error($process_mt5_fail, $mt5_id, $deriv_account_id,
                        'Funds transfer operation completed but error in recording mt5_transfer, archive process skipped');
                    return 0;
                }

                $transfer_triggered = 1;
                $archivable         = $mt5_user->{balance} == 0 ? 1 : 0;
            }
        } catch ($e) {
            _create_error($process_mt5_fail, $mt5_id, $deriv_account_id, 'Payment MT5 Transfer failed - MT5 Balance changes reverted');

            my $mt5_balance_change_revert;

            try {
                $mt5_user = await BOM::MT5::User::Async::get_user($mt5_id);

                if ($mt5_user->{balance} == ($mt5_balance_before - $mt5_transfer_amount)) {
                    $mt5_balance_change_revert = await BOM::MT5::User::Async::user_balance_change({
                        login        => $mt5_id,
                        user_balance => $mt5_transfer_amount,
                        comment      => "Revert due to failed auto transfer to [$deriv_account_id]",
                        type         => 'balance'
                    });
                }

            } catch ($e) {
                $log->errorf("MT5 Account %s: Failed to revert balance update", $mt5_id);
            }

            _create_error($process_mt5_fail, $mt5_id, $deriv_account_id,
                'Payment MT5 Transfer failed - MT5 Balance modified and may failed to revert. Manual check required.')
                if not $mt5_balance_change_revert->{status} and $mt5_balance_change->{status};

            return 0;
        }
    }

    return {
        $transfer_triggered
        ? (
            transferred_deriv     => $deriv_account_id,
            transferred_mt5_value => $mt5_transfer_amount
            )
        : (),
        archivable        => $archivable,
        remaining_balance => $mt5_user->{balance},
    };
}

=head2 _record_mt5_transfer

Record the transfer details to DB.

=over 4

=item * C<$dbic> - Reference of User Client's DBIC for database query

=item * C<$payment_id> - Payment ID generated from payment mt5 transfer process

=item * C<$mt5_amount> - The amount of funds transferred from mt5 account

=item * C<$mt5_account_id> - The mt5 account ID used to perform the funds transfer

=item * C<$mt5_currency_code> - The currency type that belongs to the mt5 account

=back

Return C<1> acknowledge successful operation.

=cut

sub _record_mt5_transfer {
    my ($dbic, $payment_id, $mt5_amount, $mt5_account_id, $mt5_currency_code) = @_;

    try {
        $dbic->run(
            ping => sub {
                $_->do("SELECT * FROM payment.add_mt5_transfer_record(?, ?, ?, ?)",
                    undef, $payment_id, $mt5_amount, $mt5_account_id, $mt5_currency_code);
            });
    } catch ($e) {
        return 0;
    }

    return 1;
}

=head2 _archive_mt5_account

Perform the archival process of provided mt5 account.

=over 4

=item * C<$mt5_prefix_id> - MT5 account id with MT* as prefix

=item * C<$mt5_user> - MT5 account instance obtained from get user call

=item * C<$bom_user> - Bom user instance

=back

Return C<1> acknowledge successful operation.

=cut

async sub _archive_mt5_account {
    my $params = shift;
    my ($mt5_prefix_id, $mt5_user, $bom_user) = @{$params}{qw/mt5_prefix_id mt5_user bom_user/};

    delete $mt5_user->{color};
    await BOM::MT5::User::Async::update_user({
        %{$mt5_user},
        login  => $mt5_user->{login},
        rights => USER_RIGHT_TRADE_DISABLED
    });

    await BOM::MT5::User::Async::user_archive($mt5_user->{login});

    $bom_user->update_loginid_status($mt5_prefix_id, 'archived');

    BOM::Platform::Event::Emitter::emit('mt5_archived_account_reset_trading_password', {email => $mt5_user->{email}},);

    return 1;
}

=head2 _send_closure_email

Notify the closure of mt5 account using the account's attached email.

=over 4

=item * C<$archived_list> - Reference to hash of mt5 accounts with successful processing, contains information on transfer details

=back

Return C<1> acknowledge successful operation.

=cut

sub _send_closure_email {
    my $archived_list = shift;

    foreach my $bom_email (keys %$archived_list) {
        my @mt5_accounts;
        foreach my $mt5_account ($archived_list->{$bom_email}{mt5_accounts}->@*) {
            my $group_details = parse_mt5_group($mt5_account->{group});

            push @mt5_accounts,
                +{
                login => $mt5_account->{login},
                name  => $mt5_account->{name},
                type  => join ' ',
                ($group_details->{account_type} // '', $group_details->{market_type} // 'mt5'),
                };
        }

        my $transfer_targets = $archived_list->{$bom_email}{transfer_targets} // [];

        my $req = BOM::Platform::Context::Request->new(language => $archived_list->{$bom_email}{bom_user}->preferred_language // 'en');
        request($req);

        BOM::Platform::Event::Emitter::emit(
            'mt5_inactive_account_closed',
            {
                email        => $archived_list->{$bom_email}{bom_user}->email,
                mt5_accounts => \@mt5_accounts,
                transferred  => join(', ', @$transfer_targets),
            },
        );
    }

    return 1;
}

=head2 _send_mt5_rescind_report

Send a Summary report about the result of auto rescind process.

=over 4

=item * C<$args> - hashref with the following keys

=item * C<$processed_mt5_accountsr> - Reference to list of mt5 accounts processed

=item * C<$success_case> - Reference to hash of mt5 accounts with successful processing, contains information on transfer details

=item * C<$failed_case> - Reference to hash of mt5 accounts with failed processing, contains information of why it failed the process.

=back

Return C<1> acknowledge successful operation.

=cut

sub _send_mt5_rescind_report {
    my $args = shift;
    my ($mt5_accounts, $process_mt5_success, $process_mt5_fail, $skip_archive) =
        @{$args}{qw/processed_mt5_accounts success_case failed_case skip_archive/};
    my $total_process_num = @$mt5_accounts;
    my $total_success_num = 0;
    my $total_failed_num  = 0;
    my $success_csv       = path('/tmp/rescind_success_report.csv');
    my $failed_csv        = path('/tmp/rescind_failed_report.csv');
    my @message           = ('<h1>MT5 Auto Rescind Report</h1><br>');

    return 0 unless ($total_process_num);

    $success_csv->remove if $success_csv->exists;
    $failed_csv->remove  if $failed_csv->exists;

    $success_csv->append("mt5_account,mt5_account_currency,mt5_balance,deriv_account,deriv_account_currency,deriv_transferred_amount\n");
    $failed_csv->append("mt5_account, error_type, error_message\n");

    push @message, ('<b>MT5 Processed: </b>', join(', ', @$mt5_accounts), '<br>');

    my (@success_mt5_list, @success_mt5_list_summary);
    foreach my $bom_email (keys %$process_mt5_success) {
        foreach my $mt5_account ($process_mt5_success->{$bom_email}{mt5_accounts}->@*) {
            push @success_mt5_list, $mt5_account->{login};
            my $csv_line;
            if (defined($process_mt5_success->{$bom_email}{$mt5_account->{login}})) {
                my $transfer_details = $process_mt5_success->{$bom_email}{$mt5_account->{login}};
                my $transfer_report  = join(
                    ' ',
                    (
                        '<b>-</b>',                                           $mt5_account->{login},
                        ($skip_archive ? "(Archive Skipped)" : "(Archived)"), "Transferred",
                        $transfer_details->{transferred_mt5_currency},        $transfer_details->{transferred_mt5_amount},
                        "to",                                                 $transfer_details->{transferred_deriv},
                        'With Value of',                                      $transfer_details->{transferred_deriv_currency},
                        $transfer_details->{transferred_deriv_amount},        '<br>'
                    ));

                $csv_line = join ',',
                    (
                    $mt5_account->{login},
                    map { $transfer_details->{$_} }
                        qw(transferred_mt5_currency transferred_mt5_amount transferred_deriv transferred_deriv_currency transferred_deriv_amount)
                    );
                $csv_line .= "\n";
                push @success_mt5_list_summary, $transfer_report;
            } else {
                $csv_line = $mt5_account->{login} . "\n";
                push @success_mt5_list_summary,
                    join(' ', ('<b>-</b>', $mt5_account->{login}, ($skip_archive ? "(Archive Skipped)" : "(Archived)"), "No Transfer<br>"));
            }
            $success_csv->append($csv_line);
        }
    }

    if (@success_mt5_list) {
        push @message,
            (
            '<br><b>###SUCCESS CASE###</b><br>',
            '<b>Auto Rescind Successful for: </b>',
            join(', ', @success_mt5_list),
            '<br>',                    '<b>Success Result Details:</b><br>',
            @success_mt5_list_summary, '<br>'
            );

        $total_success_num = @success_mt5_list;
    }

    if (scalar(keys %$process_mt5_fail)) {
        push @message,
            (
            '<br><b>###FAILED CASE###</b><br>',
            '<b>Auto Rescind Failed for: </b>',
            join(', ', keys %$process_mt5_fail),
            '<br>', '<b>Failed Result Details:</b><br>'
            );

        $total_failed_num = keys %$process_mt5_fail;
    }

    foreach my $failed_mt5 (keys %$process_mt5_fail) {
        push @message, '<b>-</b> ' . $failed_mt5 . '<br>';

        for my $error_type (keys %{$process_mt5_fail->{$failed_mt5}}) {
            my $csv_line = join(',', ($failed_mt5, $error_type, $process_mt5_fail->{$failed_mt5}{$error_type}));
            $csv_line .= "\n";
            $failed_csv->append($csv_line);
            push @message, join(' ', ('&nbsp&nbsp*', $error_type, ':', $process_mt5_fail->{$failed_mt5}{$error_type}, '<br>'));
        }
    }

    push @message,
        (
        "<br>Total MT5 Accounts Processed: $total_process_num<br>",
        "Total MT5 Accounts Processed (Succeed): $total_success_num<br>",
        "Total MT5 Accounts Processed (Failed): $total_failed_num<br>",
        '<br><b>###END OF REPORT###</b><br>'
        );

    my $brand          = request()->brand;
    my $csv_attachment = [];
    push @$csv_attachment, $success_csv->[0] if @success_mt5_list;
    push @$csv_attachment, $failed_csv->[0]  if scalar(keys %$process_mt5_fail);

    BOM::Platform::Email::send_email({
        to                    => 'i-payments-notification@deriv.com',
        from                  => $brand->emails('no-reply'),
        email_content_is_html => 1,
        subject               => 'MT5 Account Rescind Report',
        message               => \@message,
        attachment            => $csv_attachment,
    });

    return 1;
}

=head2 _create_error

Record the error message to its corresponding type and related mt5 account.

=over 4

=item * C<$error_record> - Reference to hash to record failed mt5 account and its reason

=item * C<$mt5_account_id> - MT5 account ID that failed the condition

=item * C<$error_type> - Type of error in relation to its message

=item * C<$error_message> - Message detailing on the error

=back

=cut

sub _create_error {
    my ($error_record, $mt5_account_id, $error_type, $error_message) = @_;
    $error_record->{$mt5_account_id}{$error_type} = $error_message;
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

=head2 sync_mt5_accounts_status

Update the loginid.status of mt5 accounts in users DB based on POI and POA.

=over 4

=item * C<client_loginid> - Client intance's loginid

=back

=cut

async sub sync_mt5_accounts_status {
    my $args = shift;
    die 'Must provide client_loginid' unless $args->{client_loginid};
    my $client = BOM::User::Client->new({loginid => $args->{client_loginid}}) // die 'Client not found';
    my $user   = $client->user                                                // die 'User not found';

    my $loginid_details = $user->loginid_details;

    my %jurisdiction_mt5_accounts;
    foreach my $loginid (keys %{$loginid_details}) {
        my $loginid_data = $loginid_details->{$loginid};
        next unless ($loginid_data->{platform} // '') eq 'mt5' and $loginid_data->{account_type} eq 'real';
        my $mt5_jurisdiction;
        if (defined $loginid_data->{attributes}->{group}) {
            ($mt5_jurisdiction) = $loginid_data->{attributes}->{group} =~ m/(bvi|vanuatu|labuan|maltainvest)/g;
        }

        next if not defined $mt5_jurisdiction;

        # it's important to process undef status to lookback for possible authentication
        # removals from whatever reason, it should be responsibility of the invoker if the
        # client should have been checked imho anyway
        next
            if none { ($loginid_data->{status} // 'active') eq $_ }
            ('poa_pending', 'poa_failed', 'poa_rejected', 'proof_failed', 'verification_pending', 'poa_outdated', 'active');

        push $jurisdiction_mt5_accounts{$mt5_jurisdiction}->@*, $loginid;
    }

    my %color_update_result;
    my %jurisdiction_update_result;
    foreach my $jurisdiction (keys %jurisdiction_mt5_accounts) {
        my $proof_failed_with_status;
        my $rule_failed = 0;
        my $rule_engine = BOM::Rules::Engine->new(client => $client);
        try {
            $rule_engine->verify_action(
                'mt5_jurisdiction_validation',
                loginid              => $client->loginid,
                new_mt5_jurisdiction => $jurisdiction,
                loginid_details      => $loginid_details,
            );
        } catch ($error) {
            $proof_failed_with_status = $error->{params}->{mt5_status} if $error->{params}->{mt5_status};
            $rule_failed              = 1;
        }

        if ($rule_failed and not defined $proof_failed_with_status) {
            $log->warn('Unexpected behavior. MT5 accounts sync rule failed without mt5 status');
            next;
        }

        my $mt5_ids = $jurisdiction_mt5_accounts{$jurisdiction};

        $jurisdiction_update_result{$jurisdiction} = $proof_failed_with_status;
        foreach my $mt5_id (@$mt5_ids) {
            my $current_status = $loginid_details->{$mt5_id}->{status} // '';
            $user->update_loginid_status($mt5_id, $proof_failed_with_status // undef);

            my $color_code;
            $color_code = COLOR_RED  if ($proof_failed_with_status // '') eq 'poa_failed';
            $color_code = COLOR_NONE if $current_status eq 'poa_failed' and not defined $proof_failed_with_status;

            if (defined $color_code) {
                BOM::Platform::Event::Emitter::emit(
                    'mt5_change_color',
                    {
                        loginid => $mt5_id,
                        color   => $color_code,
                    });

                $color_update_result{$jurisdiction} = $color_code;
            }

        }
    }

    return Future->done({
        processed_mt5  => \%jurisdiction_mt5_accounts,
        updated_status => \%jurisdiction_update_result,
        updated_color  => \%color_update_result
    });
}

=head2 mt5_archive_restore_sync

Update the loginid.status in users DB from archived to null. Restore of MT5 account from MT5 database.

=over 4

=item * C<mt5_accounts> - user's login id

=back

=cut

async sub mt5_archive_restore_sync {
    my $args         = shift;
    my @mt5_accounts = @{$args->{mt5_accounts} // []};

    die 'Must provide list of MT5 loginids' unless $args->{mt5_accounts};

    my $process_mt5_success = {};
    my $process_mt5_fail    = {};
    foreach my $mt5_account (@mt5_accounts) {
        my $is_mt5_archived = 0;
        my $mt5_user;
        try {
            $mt5_user = await BOM::MT5::User::Async::get_user($mt5_account);
            die unless $mt5_user->{email};
        } catch ($e) {
            $is_mt5_archived = 1;
            try {
                $mt5_user = await BOM::MT5::User::Async::get_user_archive($mt5_account);
            } catch ($e) {
                $is_mt5_archived = 0;
            }
        }

        unless ($mt5_user->{email}) {
            _create_error($process_mt5_fail, $mt5_account, 'MT5 Error', 'Failed to retrieve MT5 account data.');
            next;
        }

        my $bom_user        = BOM::User->new(email => $mt5_user->{email});
        my $loginid_details = $bom_user->loginid_details;
        my $account_data    = $loginid_details->{$mt5_account};

        unless ($account_data) {
            _create_error($process_mt5_fail, $mt5_account, 'Loginid DB Error', 'Failed to retrieve MT5 account data in Internal Database.');
            next;
        }

        my %existing_groups;
        my @mt5_logins = $bom_user->get_mt5_loginids;
        foreach my $loginid_mt5 (@mt5_logins) {
            next if $loginid_mt5 eq $mt5_account;
            my $loginid_data = $loginid_details->{$loginid_mt5};
            next unless $loginid_data->{attributes}->{group};
            $existing_groups{$loginid_data->{attributes}->{group}} = $loginid_data->{loginid};
        }

        my $current_group = $account_data->{attributes}->{group};
        unless ($current_group) {
            _create_error($process_mt5_fail, $mt5_account, 'Loginid DB Error', 'No group data found in loginid DB.');
            next;
        }

        if (my $identical = _is_identical_group($current_group, \%existing_groups)) {
            _create_error($process_mt5_fail, $mt5_account, 'Loginid DB Error', 'Found existing active MT5 account with same group.');
            next;
        }

        # Update mt5 account's status to null/undef, which indicated as active account.
        if (($account_data->{status} // '') eq 'archived') {
            try {
                $bom_user->update_loginid_status($mt5_account, undef);
                $process_mt5_success->{$mt5_account}->{dbcase} = 1;
            } catch ($e) {
                _create_error($process_mt5_fail, $mt5_account, 'Loginid DB Error', 'Failed to update MT5 status to null.');
                next;
            }
        }

        # Restore MT5 account from MT5's archive database to current database.
        if ($is_mt5_archived) {
            try {
                my $data = await BOM::MT5::User::Async::user_restore($mt5_user);
                die unless $data->{status};
                $process_mt5_success->{$mt5_account}->{mt5servercase} = 1;
            } catch ($e) {
                _create_error($process_mt5_fail, $mt5_account, 'MT5 Error', 'Failed to restore account from MT5 archive database.');
                next;
            }

            try {
                delete $mt5_user->{color};
                await BOM::MT5::User::Async::update_user({
                    %{$mt5_user},
                    login  => $mt5_user->{login},
                    rights => USER_RIGHT_ENABLED
                });
            } catch ($e) {
                _create_error($process_mt5_fail, $mt5_account, 'MT5 Error', 'MT5 restored but failed to enable trading rights.');
                next;
            }
        }
    }

    my (@success_case, @failed_case, @message);
    foreach my $mt5 (keys %$process_mt5_success) {
        my $success_message = "$mt5: ";
        $success_message .= 'Updated loginid database status. '    if $process_mt5_success->{$mt5}->{dbcase};
        $success_message .= 'Restored from MT5 archive database. ' if $process_mt5_success->{$mt5}->{mt5servercase};
        push @success_case, $success_message;
    }

    foreach my $mt5 (keys %$process_mt5_fail) {
        my ($error_type) = keys %{$process_mt5_fail->{$mt5}};
        my $failed_message = "$mt5: " . "$error_type - " . $process_mt5_fail->{$mt5}->{$error_type};
        push @failed_case, $failed_message;
    }

    my $section_sep = '-' x 20;
    push @message, ($section_sep, 'MT5 Successfully Restored:', '<~~~', @success_case, '~~~>') if @success_case;
    push @message, ($section_sep, 'MT5 Restore Failed:',        '<~~~', @failed_case,  '~~~>') if @failed_case;

    push @message, 'No inconsistency detected, nothing is done.' unless @message;

    BOM::Platform::Email::send_email({
        to      => 'x-trading-ops@regentmarkets.com',
        from    => '<no-reply@binary.com>',
        subject => 'MT5 Archive Account Restore and Sync Report',
        message => \@message,
    });

    return Future->done(1);
}

=head2 _get_mt5_account

Get MT5 account details from users DB.

=over 4

=item * C<$db> - Reference of User Client's DBIC for database query

=item * C<$loginid> - user's login id

=back

=cut

sub _get_mt5_account {
    my $params = shift;
    my ($db, $loginid) = @{$params}{qw/db loginid/};
    return $db->dbic->run(
        fixup => sub {
            $_->selectrow_arrayref(
                'SELECT  
                        binary_user_id,
                        status,
                        attributes 
                   FROM users.loginid 
                  WHERE loginid = ?',
                undef, $loginid
            );
        });
}

=head2 _ib_affiliate_account_type

Get IB affiliate account type from users DB.

=over 4

=item * C<$db> - Reference of User Client's DBIC for database query

=item * C<$binary_user_id> - user's binary user id

=item * C<$loginid> - user's login id

=back

=cut

sub _ib_affiliate_account_type {
    my $params = shift;
    my ($db, $binary_user_id, $loginid) = @{$params}{qw/db binary_user_id loginid/};
    return $db->dbic->run(
        fixup => sub {
            $_->selectrow_array(
                'SELECT mt5_account_type
                   FROM mt5.list_user_accounts(?)
                  WHERE mt5_account_id = ?',
                undef, $binary_user_id, substr($loginid, 3));
        });
}

=head2 mt5_archive_accounts

Checks for open positions and orders, withdraws balance to a CR account
Archives MT5 Accounts

=over 4

=item * C<mt5_loginids> Arrayref - MT5 loginids

=back

=cut

async sub mt5_archive_accounts {
    my $args = shift;

    my $loginids = $args->{loginids};
    die 'Must provide list of MT5 loginids' unless $loginids and @$loginids;

    my $staff_name = $args->{staff_name} // 'quants';
    my $user_db    = BOM::Database::UserDB::rose_db();
    my @email_content;
    my $archive_failed_row;

    push @email_content, '<p>MT5 Archival request result<p>
    <table border=1><tr><th>Loginid</th><th>Status</th><th>Group</th><th>Comment</th></tr>';

    foreach my $loginid (@$loginids) {
        my ($binary_user_id, $status, $attributes, $bom_loginid, $client, $cr_currency, $user, $group, $withdrawal_result_message, $mt5_user);

        $archive_failed_row = "<tr><td>$loginid</td><td>Not Archived</td><td>%s</td><td>%s</td></tr>";

        try {
            my $account = _get_mt5_account({db => $user_db, loginid => $loginid});

            unless (@$account) {
                push @email_content, sprintf($archive_failed_row, 'Unknown', 'Account not found');
                next;
            }

            ($binary_user_id, $status, $attributes) = @$account;
            $attributes = $attributes ? decode_json($attributes) : {group => 'Undefined'};
            $group      = $attributes->{group};

            if ($status and $status eq 'archived') {
                push @email_content, sprintf($archive_failed_row, $group, 'Account already archived');
                next;
            }

            my $affiliate_mt5_account_type = _ib_affiliate_account_type({db => $user_db, binary_user_id => $binary_user_id, loginid => $loginid});

            if ($affiliate_mt5_account_type) {
                push @email_content, sprintf($archive_failed_row, $group, "IB $affiliate_mt5_account_type account");
                next;
            }

        } catch ($e) {
            $log->infof("MT5 archival for %s failed: [%s]", $loginid, $e);
            push @email_content, sprintf($archive_failed_row, 'Unknown', 'Fetching account failed');
            next;
        }

        my ($open_orders, $open_positions);
        try {
            $open_orders    = await BOM::MT5::User::Async::get_open_orders_count($loginid);
            $open_positions = await BOM::MT5::User::Async::get_open_positions_count($loginid);
        } catch ($e) {
            $log->errorf("MT5 archival for %s failed: [%s]", $loginid, $e);
            my $error_message = "Can't check MT5 orders and positions";
            $error_message .= ", account doesn't exist on MT5" if (ref($e) eq 'HASH' and $e->{code} eq 'NotFound');

            push @email_content, sprintf($archive_failed_row, $group, $error_message);
            next;
        }

        if ($open_orders->{total} or $open_positions->{total}) {
            push @email_content, sprintf($archive_failed_row, $group, 'Account has open orders or positions');
            next;
        }

        try {

            # Get user to check balance
            $mt5_user = await BOM::MT5::User::Async::get_user($loginid);

            # Don't archive if negative balance
            if ($mt5_user->{balance} and $mt5_user->{balance} < 0) {
                push @email_content, sprintf($archive_failed_row, $group, 'The account has a negative balance');
                next;
            }

            $user = BOM::User->new((id => $binary_user_id));

            # Check balance and withdraw
            if ($mt5_user->{balance} and $mt5_user->{balance} > 0) {

                $client = $user->accounts_by_category([$user->bom_real_loginids])->{enabled}->[0];
                unless ($client) {
                    push @email_content, sprintf($archive_failed_row, $group, 'CR account for the withdrawal process not found');
                    next;
                }

                $bom_loginid = $client->loginid;
                $cr_currency = $client->currency;

                unless ($client->db->dbic->connected) {
                    $log->infof("MT5 archival for %s failed: [%s]", $loginid, 'DB connection lost');
                    push @email_content, sprintf($archive_failed_row, $group, 'Technical issue, try again later');
                    next;
                }

                my $group_currency = await BOM::MT5::User::Async::get_group($group);
                $group_currency = $group_currency->{currency};

                my $transfer_amount =
                    $group_currency ne $cr_currency
                    ? convert_currency($mt5_user->{balance}, $group_currency, $cr_currency)
                    : $mt5_user->{balance};

                $transfer_amount = financialrounding('price', $cr_currency, $transfer_amount);

                my $withdraw_response = await BOM::MT5::User::Async::withdrawal({
                    login   => $loginid,
                    amount  => $mt5_user->{balance},
                    comment => $loginid . '_' . $bom_loginid,
                });

                if ($withdraw_response->{status}) {

                    my ($txn) = $client->payment_mt5_transfer(
                        currency => $cr_currency,
                        amount   => $transfer_amount,
                        remark   => "Transfer from MT5 account "
                            . $loginid . " to "
                            . $bom_loginid . " "
                            . $cr_currency
                            . $mt5_user->{balance} . " to "
                            . $group_currency
                            . $transfer_amount,
                        staff  => $staff_name,
                        fees   => 0,
                        source => 1
                    );

                    $client->db->dbic->run(
                        fixup => sub {
                            my $sth = $_->prepare(
                                'INSERT INTO payment.mt5_transfer
                                (payment_id, mt5_amount, mt5_account_id, mt5_currency_code)
                                VALUES (?,?,?,?)'
                            );
                            $sth->execute($txn->payment_id, $mt5_user->{balance}, $loginid, $group_currency);
                        });

                    $withdrawal_result_message = sprintf("[%s] Transfer from MT5 login: %s to binary account %s %s %s",
                        Time::Moment->now, $loginid, $bom_loginid, $group_currency, $mt5_user->{balance});

                } else {
                    push @email_content, sprintf($archive_failed_row, $group, 'Failed to perform withdrawal');
                    next;
                }

            }

        } catch ($e) {
            $log->errorf("MT5 archival for %s failed: [%s]", $loginid, $e);
            push @email_content, sprintf($archive_failed_row, $group, 'Failed to check balance or to perform withdrawal');
            next;
        }

        my $archival_result = await _archive_mt5_account({mt5_prefix_id => $loginid, mt5_user => $mt5_user, bom_user => $user});
        unless ($archival_result) {
            push @email_content, sprintf($archive_failed_row, $group, 'Performed withdrawal but failed to archive ' . $withdrawal_result_message);
            next;
        }

        push @email_content,
              "<tr><td>$loginid</td><td>Archived</td><td>$group</td><td>"
            . ($withdrawal_result_message || 'Archived successfully, account had zero balance')
            . "</td></tr>";
    }

    push @email_content, '</table>';
    my $brand = Brands->new();
    BOM::Platform::Event::Emitter::emit(
        'send_email',
        {
            from                  => $brand->emails('system'),
            to                    => $brand->emails('quants'),
            subject               => 'MT5 Archival request result ',
            email_content_is_html => 1,
            message               => \@email_content,
        });

}

=head2 _get_mt5_account_type_config

Get MT5 Accout Types data

=over 4

=item * C<group_name> - MT5 account's group

=back

=cut

sub _get_mt5_account_type_config {
    my ($group_name) = shift;

    my $group_accounttype = lc($group_name);

    return BOM::Config::mt5_account_types()->{$group_accounttype};
}

=head2 _is_identical_group

Check if current MT5 account group already exist in existing group data.

=over 4

=item * C<group> - Current MT5 account's group

=item * C<existing_groups> - hash refetences of MT5 accounts' group.

=back

=cut

sub _is_identical_group {
    my ($group, $existing_groups) = @_;

    my $group_config = _get_mt5_account_type_config($group);

    foreach my $existing_group (map { _get_mt5_account_type_config($_) } keys %$existing_groups) {
        return $existing_group if defined $existing_group and all { $group_config->{$_} eq $existing_group->{$_} } keys %$group_config;
    }

    return undef;
}

=head2 mt5_deposit_retry

Retry attempt for mt5 deposit

=cut

async sub mt5_deposit_retry {
    my ($parameters) = @_;

    # Set up the parameters from redis stream
    my ($from_login_id, $destination_mt5_account, $amount, $mt5_comment, $server, $transaction_id, $datetime_start, $retry_last) =
        @{$parameters}{qw/from_login_id destination_mt5_account amount mt5_comment server transaction_id datetime_start retry_last/};

    # Create a client
    my $client = BOM::User::Client->new({loginid => $from_login_id});

    # Get the end datetime
    $datetime_start = Date::Utility->new($datetime_start)->minus_time_interval('5m')->epoch;
    my $datetime_end = Date::Utility->new()->plus_time_interval('5m')->epoch;

    # Set up the parameters for the MT5 API call
    my $params = {
        server => $server,
        login  => $destination_mt5_account,
        from   => $datetime_start,
        to     => $datetime_end,
    };

    # Validate the parameters
    die 'Need transaction_id to proceed with deposit retry' if !$transaction_id;
    die 'Do not need to try demo deposit'                   if $server =~ /^demo/;
    die "Cannot find transaction id: $transaction_id"       if !$client->account->find_transaction(query => [id => $transaction_id]);

    # Log the parameters
    $log->debugf("Deposit retry parameters: %s", $parameters);

    # Get the deals
    my $deals = await BOM::MT5::User::Async::deal_get_batch($params);

    # Log the deals
    $log->debugf("Deals: %s", $deals);

    # Check if the transaction already exists
    if (any { $_->{'comment'} =~ /#(\d+)$/ && $1 eq $transaction_id } @{$deals->{deal_get_batch}}) {
        $log->infof("Transaction already exists in MT5. Skipping deposit retry.");

        # Remove lock for mt5 deposit lock on account level
        _remove_temporary_account_lock($destination_mt5_account);

        return Future->done('Transaction already exist in mt5');
    }

    # Deposit the money
    $log->infof("Transaction not found in MT5. Attempting deposit retry.");
    return await BOM::MT5::User::Async::deposit({
            login   => $destination_mt5_account,
            amount  => $amount,
            comment => $mt5_comment,
            txn_id  => $transaction_id,
        }
    )->then(
        sub {
            my $result = shift;

            # Remove lock for mt5 deposit lock on account level
            _remove_temporary_account_lock($destination_mt5_account);

            return $result;
        }
    )->catch(
        sub {
            my $error = shift;

            if ($retry_last) {
                # Send email notification for MT5 deposit errors
                my $brand   = request()->brand;
                my $message = "Error occurred when processing MT5 deposit after withdrawal from client account:";

                send_email({
                    from    => $brand->emails('system'),
                    to      => $brand->emails('payments'),
                    subject => "MT5 deposit error",
                    message =>
                        [$message, "Client login id: $from_login_id", "MT5 login: $destination_mt5_account", "Amount: $amount", "error: $error"],
                    use_email_template    => 1,
                    email_content_is_html => 1,
                    template_loginid      => 'real ' . $destination_mt5_account,
                });
            }

            $log->errorf("Failed to retry deposit: %s", $error);

            return Future->fail($error);
        });
}

=head2 _remove_temporary_account_lock

Removes the temporary account lock.

=over 4

=item * C<$mt5_id> - The ID of the MT5 account

=back

Returns: undef

=cut

async sub _remove_temporary_account_lock {
    my ($mt5_id)           = @_;
    my $lock_key           = "TRANSFER::BLOCKED::$mt5_id";
    my $redis_events_write = BOM::Config::Redis::redis_events_write();

    try {
        # Check if the account deposit lock exists
        my $get_account_deposit_lock = $redis_events_write->get($lock_key);

        if ($get_account_deposit_lock) {
            # Delete the account deposit lock
            $redis_events_write->del($lock_key);
        }
    } catch ($err) {
        # Log the error if removing the lock fails
        $log->errorf(sprintf("Failed to remove lock_key: %s, Error: %s", $lock_key, $err));
    }

    return undef;
}

=head2 mt5_svg_migration_requested

Placeholder

=over 4

=item * C<client_loginid> - Client loginid

=item * C<market_type> - Market type (financial|synthetic)

=item * C<jurisdiction> - Jurisdiction (bvi|vanuatu)

=back

=cut

async sub mt5_svg_migration_requested {
    my $args = shift;
    my ($client_loginid, $market_type, $jurisdiction, $logins) = @{$args}{qw/client_loginid market_type jurisdiction logins/};
    my $client = BOM::User::Client->new({loginid => $client_loginid});

    die 'No client found'                       unless $client;
    die 'Need to provide market_type argument'  unless $market_type;
    die 'Need to provide jurisdiction argument' unless $jurisdiction;
    die 'Need to provide logins argument'       unless defined $logins;

    @$logins = grep { not $_->{error} } @$logins;

    # Skip swap free and no migration at all for lim and ib type account
    my @accounts_to_migrate;
    my $abort_migrate_flag = 0;
    foreach my $mt5_account (@$logins) {
        next unless $mt5_account->{account_type} eq 'real';
        next unless $mt5_account->{market_type} eq $market_type;
        next unless $mt5_account->{group} =~ m/svg/;
        next if $mt5_account->{sub_account_category} =~ m/(swap_free)/;

        if (not defined $mt5_account->{comment} or $mt5_account->{group} =~ m/(lim)/ or $mt5_account->{comment} =~ m/(IB)/) {
            $abort_migrate_flag = 1;
            DataDog::DogStatsd::Helper::stats_event(
                'MT5AccountMigrationSkipped',
                "Aborted migration for $client_loginid on $market_type/$jurisdiction",
                {alert_type => 'warning'});
            last;
        }

        push @accounts_to_migrate, $mt5_account;
    }

    unless ($abort_migrate_flag) {
        foreach my $mt5_account (@accounts_to_migrate) {

            try {

                my $has_open_order_position = 0;

                # Get the number of open orders
                my $number_open_order = await BOM::MT5::User::Async::get_open_orders_count($mt5_account->{login});
                $has_open_order_position = 1 if (ref $number_open_order eq 'HASH' && $number_open_order->{total} > 0);

                # Check if there are no open orders
                unless ($has_open_order_position) {
                    # Get the number of open positions
                    my $number_open_position = await BOM::MT5::User::Async::get_open_positions_count($mt5_account->{login});
                    $has_open_order_position = 1 if (ref $number_open_position eq 'HASH' && $number_open_position->{total} > 0);
                }

                unless ($has_open_order_position) {
                    my $retry = 5;
                    await try_repeat {
                        BOM::MT5::User::Async::update_user({
                            login  => $mt5_account->{login},
                            rights => USER_RIGHT_TRADE_DISABLED | USER_RIGHT_ENABLED
                        });

                    }
                    until => sub {
                        my $f = shift;
                        return $f if $f->is_done;
                        return 1 unless $retry--;
                        return 0;
                    };

                    $client->user->update_loginid_status($mt5_account->{login}, 'migrated_without_position');
                } else {
                    BOM::Platform::Event::Emitter::emit(
                        'mt5_change_color',
                        {
                            loginid => $mt5_account->{login},
                            color   => COLOR_BLACK,
                        });

                    $client->user->update_loginid_status($mt5_account->{login}, 'migrated_with_position');
                }

                DataDog::DogStatsd::Helper::stats_inc('mt5.account.migration',
                    {tags => ['market_type:' . $market_type, 'jurisdiction:' . $jurisdiction]});

            } catch ($e) {
                DataDog::DogStatsd::Helper::stats_event(
                    'MT5AccountMigrationFailed',
                    "Failed to migrate $client_loginid on $market_type/$jurisdiction",
                    {alert_type => 'error'});
            }
        }
    }

    return Future->done(1);

}

1;
