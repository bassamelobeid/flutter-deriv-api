package BOM::OAuth::Common;

use strict;
use warnings;
no indirect;

use DataDog::DogStatsd::Helper qw( stats_inc );
use Email::Valid;
use Format::Util::Strings qw( defang );
use HTTP::BrowserDetect;
use List::Util qw( first min none );
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Text::Trim;

use BOM::Config::Runtime;
use BOM::Database::Model::OAuth;
use BOM::OAuth::Static qw( get_message_mapping get_valid_device_types );
use BOM::Platform::Context qw( localize request );
use BOM::Platform::Email qw( send_email );
use BOM::User;
use BOM::User::AuditLog;
use BOM::Platform::Account::Virtual;

# Time in seconds we'll start blocking someone for repeated bad logins from the same IP
use constant BLOCK_MIN_DURATION => 5 * 60;
# Upper limit in seconds we'll block an IP  for
use constant BLOCK_MAX_DURATION => 24 * 60 * 60;
# How long in seconds before we reset (expire) the exponential backoff
use constant BLOCK_TTL_RESET_AFTER => 24 * 60 * 60;
# How many failed attempts (not necessarily consecutive) before we block this IP
use constant BLOCK_TRIGGER_COUNT => 10;
# How much time in seconds with no failed attempts before we reset (expire) the failure count
use constant BLOCK_TRIGGER_WINDOW => 5 * 60;

=head2 validate_login

Validate the email and password inputs. Return the user object
and list of associated clients, upon successful validation. Otherwise,
return the error code

=cut

sub validate_login {
    my ($login_details) = @_;

    my $err_var = sub {
        my ($error_code, $error_msg) = @_;
        return {
            error_code => $error_code,
            defined $error_msg ? (error_msg => $error_msg) : ()};
    };

    my $c              = delete $login_details->{c};
    my $oneall_user_id = delete $login_details->{oneall_user_id};
    my $app            = delete $login_details->{app};
    my $email          = delete $login_details->{email};
    my $password       = delete $login_details->{password};

    my $app_id = $app->{id};

    my $user;

    if ($oneall_user_id) {

        $user = BOM::User->new(id => $oneall_user_id);
        return $err_var->("INVALID_USER") unless $user;

        $password = '**SOCIAL-LOGIN-ONEALL**';

    } else {

        return $err_var->("INVALID_EMAIL")    unless ($email and Email::Valid->address($email));
        return $err_var->("INVALID_PASSWORD") unless $password;

        $user = BOM::User->new(email => $email);

        return $err_var->("INVALID_CREDENTIALS") unless $user;
        # Prevent login if social signup flag is found.
        # As the main purpose of this controller is to serve
        # clients with email/password only.

        return $err_var->("INVALID_CREDENTIALS") if $user->{has_social_signup};
    }

    if (BOM::Config::Runtime->instance->app_config->system->suspend->all_logins) {

        BOM::User::AuditLog::log('system suspend all login', $user->{email});
        return $err_var->("TEMP_DISABLED");
    }

    my $env              = request()->login_env({user_agent => $c->req->headers->header('User-Agent')});
    my $unknown_location = !$user->logged_in_before_from_same_location($env);

    my $result = $user->login(
        password        => $password,
        environment     => $env,
        is_social_login => $oneall_user_id ? 1 : 0,
        app_id          => $app_id
    );

    # Self-closed error is treated like a success; we'll try to reactivate accounts.
    if (($result->{error_code} // '') eq 'AccountSelfClosed') {
        $result = {
            success     => 1,
            self_closed => 1,
        };
    }

    return $err_var->(@{$result}{qw/error_code error/}) if exists $result->{error};

    my @clients = $user->clients(include_self_closed => $result->{self_closed});
    my $client  = $clients[0];

    return $err_var->("TEMP_DISABLED") if grep { $client->loginid =~ /^$_/ } @{BOM::Config::Runtime->instance->app_config->system->suspend->logins};

    my $client_is_disabled = $client->status->disabled && !($result->{self_closed} && $client->status->closed);
    return $err_var->("DISABLED") if ($client->status->is_login_disallowed or $client_is_disabled);

    # For self-closed accounts the following step is postponed until reactivation is finalized.
    notify_login($c, $client, $unknown_location, $app) unless $result->{self_closed};

    return {
        clients      => \@clients,
        user         => $user,
        login_result => $result,
    };
}

=head2 notify_login

Tracks the login event and notifies client about successful login form a new (unknown) location.

=cut

sub notify_login {
    my ($c, $client, $unknown_location, $app) = @_;

    my $bd           = HTTP::BrowserDetect->new($c->req->headers->header('User-Agent'));
    my $country_code = uc($c->stash('request')->country_code // '');
    my $brand        = $c->stash('brand');
    my $request      = $c->stash('request');
    my $ip           = $request->client_ip || '';

    if (!$c->session('_is_social_signup')) {
        BOM::Platform::Event::Emitter::emit(
            'login',
            {
                loginid    => $client->loginid,
                properties => {
                    ip                  => $ip,
                    location            => $brand->countries_instance->countries->country_from_code($country_code) // $country_code,
                    browser             => $bd->browser,
                    device              => $bd->device // $bd->os_string,
                    new_signin_activity => $unknown_location ? 1 : 0,
                }});
    }

    if ($unknown_location && $brand->send_signin_email_enabled()) {
        my $email_data = {
            name        => $client->first_name,
            title       => localize("New device login"),
            client_name => $client->first_name
            ? ' ' . $client->first_name . ' ' . $client->last_name
            : '',
            country                   => $brand->countries_instance->countries->country_from_code($country_code) // $country_code,
            device                    => $bd->device                                                             // $bd->os_string,
            browser                   => $bd->browser_string                                                     // $bd->browser,
            app                       => $app,
            ip                        => $ip,
            language                  => lc($request->language),
            start_url                 => 'https://' . lc($brand->website_name),
            is_reset_password_allowed => is_reset_password_allowed($app->{id}),
        };

        send_email({
            to                    => $client->email,
            subject               => localize(get_message_mapping()->{NEW_SIGNIN_SUBJECT}),
            template_name         => 'unknown_login',
            template_args         => $email_data,
            template_loginid      => $client->loginid,
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 1
        });
    }
}

sub is_reset_password_allowed {
    my $app_id = shift;

    die "Invalid application id." unless $app_id;

    return BOM::Database::Model::OAuth->new->is_primary_website($app_id);
}

# fetch social login feature status from settings
sub is_social_login_suspended {
    return BOM::Config::Runtime->instance->app_config->system->suspend->social_logins;
}

=head2 failed_login_attempt

Called for failed manual login attempt.
Increments redis counts and may set a blocking flag.

=cut

sub failed_login_attempt {
    my $c = shift;

    stats_inc('login.authorizer.login_failed');

    # Something went wrong - most probably login failure. Innocent enough in isolation;
    # if we see a pattern of failures from the same address, we would want to discourage
    # further attempts.
    my $ip = $c->stash('request')->client_ip;
    if ($ip) {
        try {
            my $redis = BOM::Config::Redis::redis_auth_write();
            my $k     = 'oauth::failure_count_by_ip::' . $ip;
            if ($redis->incr($k) > BLOCK_TRIGGER_COUNT) {
                # Note that we don't actively delete the failure count here, since we expect
                # it to expire before the block does. If it doesn't... well, this only applies
                # on failed login attempt, if you get the password right first time after the
                # block then you're home free.

                my $ttl = $redis->get('oauth::backoff_by_ip::' . $ip);
                $ttl = min(BLOCK_MAX_DURATION, $ttl ? $ttl * 2 : BLOCK_MIN_DURATION);
                $log->infof('Multiple login failures from the same IP %s, blocking for %d seconds', $ip, $ttl);

                # Record our new TTL (hangs around for a day, which we expect to be sufficient
                # to slow down offenders enough that we no longer have to be particularly concerned),
                # and also apply the block at this stage.
                $redis->set('oauth::backoff_by_ip::' . $ip, $ttl, EX => BLOCK_TTL_RESET_AFTER);
                $redis->set('oauth::blocked_by_ip::' . $ip, 1,    EX => $ttl);
                stats_inc('login.authorizer.block.add');
            } else {
                # Extend expiry every time there's a failure
                $redis->expire($k, BLOCK_TRIGGER_WINDOW);
                stats_inc('login.authorizer.block.fail');
            }
        } catch ($err) {
            $log->errorf('Failure encountered while handling Redis blocklists for failed login: %s', $err);
            stats_inc('login.authorizer.block.error');
        }
    }

}

sub get_email_by_provider {
    my ($provider_data) = @_;

    # for Google
    my $emails = $provider_data->{user}->{identity}->{emails};
    return $emails->[0]->{value};    # or need check is_verified?
}

=head2 create_virtual_account

Register user and create a virtual account for user with given information
Returns a hashref {error}/{client, user}

Arguments:

=over 1

=item C<$email>

User's email

=item C<$brand>

Company's brand

=item C<$residence>

User's country of residence

=item C<$date_first_contact>

Date of registration. It's optinal

=item C<$signup_device>

Device(platform) used for signing up on the website. It's optinal

=back

=cut

sub create_virtual_account {
    my ($user_details, $utm_data) = @_;

    my $details = {
        email             => $user_details->{email},
        client_password   => rand(999999),                 # random password so you can't login without password
        has_social_signup => 1,
        brand_name        => $user_details->{brand},
        residence         => $user_details->{residence},
        source            => $user_details->{source},
    };

    $details->{$_} = $user_details->{$_}
        for grep { $user_details->{$_} } qw (date_first_contact signup_device myaffiliates_token gclid_url utm_medium utm_source utm_campaign);

    # Validate signup_device and reset it to null in case of invalid value
    if (exists $details->{'signup_device'} && none { $_ eq $details->{'signup_device'} } get_valid_device_types) {
        $details->{'signup_device'} = undef;
    }

    return BOM::Platform::Account::Virtual::create_account({
        details  => $details,
        utm_data => $utm_data
    });
}

1;
