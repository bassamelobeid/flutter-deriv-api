package BOM::OAuth::Common;

use strict;
use warnings;
no indirect;

use DataDog::DogStatsd::Helper qw( stats_inc );
use Email::Valid;
use Format::Util::Strings qw( defang );
use HTTP::BrowserDetect;
use List::Util qw( first min none any);
use Log::Any   qw($log);
use Syntax::Keyword::Try;
use Text::Trim;
use Digest::MD5 qw( md5_hex );

use BOM::Database::Model::OAuth;
use BOM::Config::Runtime;
use BOM::OAuth::Static     qw( get_message_mapping get_valid_device_types );
use BOM::Platform::Context qw( localize request );
use BOM::User;
use BOM::User::AuditLog;
use BOM::Platform::Account::Virtual;
use BOM::User::WalletMigration;

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

    my $c                     = delete $login_details->{c};
    my $oneall_user_id        = delete $login_details->{oneall_user_id};
    my $social_user_id        = delete $login_details->{social_user_id};
    my $passkeys_user_id      = delete $login_details->{passkeys_user_id};
    my $refresh_token_user_id = delete $login_details->{user_id};
    my $refresh_token         = delete $login_details->{refresh_token};
    my $app                   = delete $login_details->{app};
    my $email                 = delete $login_details->{email};
    my $password              = delete $login_details->{password};
    my $device_id             = delete $login_details->{device_id};

    my $app_id = $app->{id};

    my $user;

    if ($refresh_token) {
        $user = BOM::User->new(id => $refresh_token_user_id);
        return $err_var->("INVALID_USER") unless $user;

        $password = '**REFRESH-TOKEN-LOGIN**';
    } elsif ($oneall_user_id) {
        $user = BOM::User->new(id => $oneall_user_id);
        return $err_var->("INVALID_USER") unless $user;

        $password = '**SOCIAL-LOGIN-ONEALL**';
    } elsif ($social_user_id) {
        $user = BOM::User->new(id => $social_user_id);
        return $err_var->("INVALID_USER") unless $user;

        $password = '**SOCIAL-LOGIN**';
    } elsif ($passkeys_user_id) {
        $user = BOM::User->new(id => $passkeys_user_id);
        return $err_var->("INVALID_USER") unless $user;
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

    if (is_login_suspended()) {
        BOM::User::AuditLog::log('system suspend all login', $user->{email});
        return $err_var->("TEMP_DISABLED");
    }

    my $env = request()->login_env({
        user_agent => $c->req->headers->header('User-Agent'),
        device_id  => $device_id,
    });

    my $unknown_location = !$user->logged_in_before_from_same_location($env);

    my $result = $user->login(
        password               => $password,
        environment            => $env,
        is_refresh_token_login => $refresh_token                       ? 1 : 0,
        is_social_login        => ($oneall_user_id || $social_user_id) ? 1 : 0,
        is_passkeys_login      => $passkeys_user_id                    ? 1 : 0,
        app_id                 => $app_id,
        device_id              => $device_id,
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

    return $err_var->("TEMP_DISABLED") if (any { is_login_suspended($_->loginid) } @clients);

    my $client_is_disabled = $client->status->disabled && !($result->{self_closed} && $client->status->closed);
    return $err_var->("DISABLED") if ($client->status->is_login_disallowed or $client_is_disabled);

    # For self-closed accounts the following step is postponed until reactivation is finalized.
    notify_login($c, $client, $unknown_location, $app) unless $result->{self_closed};

    # If migration is in progress, we hide wallet accounts from the client.
    if (BOM::User::WalletMigration::accounts_state($user) eq 'partial') {
        @clients = grep { !$_->is_wallet } @clients;
    }

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
    my $time         = time();

    if (!$c->session('_is_social_signup')) {
        BOM::Platform::Event::Emitter::emit(
            'login',
            {
                loginid    => $client->loginid,
                properties => {
                    ip                  => $ip,
                    location            => $brand->countries_instance->countries->country_from_code($country_code) // $country_code,
                    browser             => $bd->browser,
                    device              => $bd->device // $bd->os_string // '',
                    new_signin_activity => $unknown_location ? 1 : 0,
                }});
    }

    if ($unknown_location) {
        my $password_reset_url = $brand->password_reset_url({
            website_name => $brand->website_name,
            source       => $app->{id},
            language     => $request->language,
            app_name     => $app->{name},
        });

        my $email_data = {
            title                     => localize("New device login"),    # Deriv email header: https://fly.customer.io/env/89555/layouts/5
            country                   => $brand->countries_instance->countries->country_from_code($country_code) // $country_code,
            device                    => $bd->device // $bd->os_string // '',
            browser                   => $bd->browser_string // $bd->browser,
            app_name                  => $app->{name},
            ip                        => $ip,
            lang                      => lc($request->language),
            is_reset_password_allowed => is_reset_password_allowed($app->{id}),
            password_reset_url        => lc($password_reset_url),
            first_name                => $client->first_name,
        };
        BOM::Platform::Event::Emitter::emit(
            'unknown_login',
            {
                event      => 'unknown_login',
                loginid    => $client->loginid,
                properties => $email_data,
            });
    }
    BOM::Platform::Event::Emitter::emit(
        'dp_successful_login',
        {
            loginid    => $client->loginid,
            properties => {
                timestamp => $time,
            },
        });
}

sub is_reset_password_allowed {
    my $app_id = shift;

    return 0 unless $app_id;

    return BOM::Database::Model::OAuth->new->is_primary_website($app_id);
}

# fetch social login feature status from settings
sub is_social_login_suspended {
    return BOM::Config::Runtime->instance->app_config->system->suspend->social_logins;
}

=head2 failed_login_attempt

Called for failed manual login attempt.

Increments redis counts and may set a blocking flag.

It takes the following arguments:

=over 4

=item * C<$c> - a controller instance

=item * C<$user> - (optional) a L<BOM::User> instance

=back

Returns C<undef>.

=cut

sub failed_login_attempt {
    my ($c, $user) = @_;

    stats_inc('login.authorizer.login_failed');

    # Something went wrong - most probably login failure. Innocent enough in isolation;
    # if we see a pattern of failures from the same address, we would want to discourage
    # further attempts.
    if (my $ip = $c->stash('request')->client_ip) {
        failed_login_by_ip($ip);
    }

    # Applies the same treatment to ip, but to the specific user if given.
    # Most probably due to totp failure.
    if ($user) {
        failed_login_by_user($user);
    }

    return undef;
}

=head2 failed_login_by_user

Applies the login failure punishment by user.

Takes the following arguments:

=over 4

=item * C<$user> - the offending L<BOM::User> instance.

=back

Returns C<undef>.

=cut

sub failed_login_by_user {
    my $user = shift;

    _block_counter_by('user', $user->id);

    return undef;
}

=head2 failed_login_by_ip

Applies the login failure punishment by ip address.

Takes the following arguments:

=over 4

=item * C<$ip> - the offending ip address.

=back

Returns C<undef>.

=cut

sub failed_login_by_ip {
    my $ip = shift;

    _block_counter_by('ip', $ip);

    return undef;
}

=head2 _block_counter_by

Handles the login attempts counter in Redis.

It takes the following arguments:

=over 4

=item * C<$key> - what we are about to block, either 'ip' or 'user'.

=item * C<$identifier> - the ip or user id we are about to block.

=back

Returns C<undef>.

=cut

sub _block_counter_by {
    my ($key, $identifier) = @_;

    try {
        my $redis       = BOM::Config::Redis::redis_auth_write();
        my $counter_key = 'oauth::failure_count_by_' . $key . '::' . $identifier;
        my $backoff_key = 'oauth::backoff_by_' . $key . '::' . $identifier;
        my $blocked_key = 'oauth::blocked_by_' . $key . '::' . $identifier;

        if ($redis->incr($counter_key) > BLOCK_TRIGGER_COUNT) {
            # Note that we don't actively delete the failure count here, since we expect
            # it to expire before the block does. If it doesn't... well, this only applies
            # on failed login attempt, if you get the password right first time after the
            # block then you're home free.

            my $ttl = $redis->get($backoff_key);
            $ttl = min(BLOCK_MAX_DURATION, $ttl ? $ttl * 2 : BLOCK_MIN_DURATION);

            # Record our new TTL (hangs around for a day, which we expect to be sufficient
            # to slow down offenders enough that we no longer have to be particularly concerned),
            # and also apply the block at this stage.
            $redis->set($backoff_key, $ttl, EX => BLOCK_TTL_RESET_AFTER);
            $redis->set($blocked_key, 1,    EX => $ttl);
            stats_inc('login.authorizer.block.add');
        } else {
            # Extend expiry every time there's a failure
            $redis->expire($counter_key, BLOCK_TRIGGER_WINDOW);
            stats_inc('login.authorizer.block.fail');
        }
    } catch ($err) {
        $log->errorf('Failure encountered while handling Redis blocklists for failed login: %s', $err);
        stats_inc('login.authorizer.block.error');
    }

    return undef;
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
This method is used only for social login. Other account creation methods use the rpc call.

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
        account_type      => 'binary',
        email_verified    => 1,
    };

    $details->{$_} = $user_details->{$_}
        for grep { $user_details->{$_} } qw (date_first_contact signup_device myaffiliates_token gclid_url utm_medium utm_source utm_campaign);

    # Validate signup_device and reset it to null in case of invalid value
    if (exists $details->{'signup_device'} && none { $_ eq $details->{'signup_device'} } get_valid_device_types) {
        $details->{'signup_device'} = undef;
    }

    # Clients from Spain and portugal are not allowed to signup via affiliate links hence we are removing their token.
    if (exists $details->{'myaffiliates_token'} && (lc($user_details->{residence}) eq 'pt' || lc($user_details->{residence}) eq 'es')) {
        $details->{'myaffiliates_token'} = "";
    }

    return BOM::Platform::Account::Virtual::create_account({
        details  => $details,
        utm_data => $utm_data
    });
}

=head2 generate_url_token_params

Generates a url params with client loginid and token.

=over 4

=item * C<$args> contains list of clients - client ip and app_id

=back

=cut

sub generate_url_token_params {
    my ($c, $args) = @_;

    my $clients     = $args->{clients};
    my $client_ip   = $args->{ip};
    my $app_id      = $args->{app_id};
    my $oauth_model = BOM::Database::Model::OAuth->new;

    if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
        $client_ip = $c->tx->req->headers->header('REMOTE_ADDR');
    }

    my $ua_fingerprint = md5_hex($app_id . ($client_ip // '') . ($c->req->headers->header('User-Agent') // ''));

    # create tokens for all loginids
    my $i = 1;
    my @params;
    foreach my $c1 (@$clients) {
        my ($access_token) = $oauth_model->store_access_token_only($app_id, $c1->loginid, $ua_fingerprint);
        push @params,
            (
            'acct' . $i  => $c1->loginid,
            'token' . $i => $access_token,
            $c1->default_account ? ('cur' . $i => $c1->default_account->currency_code) : (),
            );
        $i++;
    }

    return @params;
}

=head2 redirect_to

Redirects to provided C<$redirect_uri> with C<$url_params> appended if any

=over 4

=item C<$c> the current connection.

=item C<$redirect_uri> the uri to redirect to

=item C<$url_params> params to append to the C<$redirect_uri>

=back

=cut

sub redirect_to {
    my ($c, $redirect_uri, $url_params) = @_;

    my $uri = Mojo::URL->new($redirect_uri);
    $uri->query($url_params) if $url_params;

    return $c->redirect_to($uri);
}

=head2 activate_accounts

Reactivates self-closed accounts of a user and sends email to client on each reactivated account.

Arguments:

=over 4

=item C<closed_clients>

An array-ref containing self-closed sibling accounts which are about to be reactivated.

=item C<app>

The db row representing the requested application.

=back

=cut

sub activate_accounts {
    my ($c, $closed_clients, $app) = @_;

    # pick one of the activated siblings by the following order of priority:
    # - social responsibility check is reqired (MLT and MX)
    # - real account with fiat currency
    # - real account with crypto currency
    my $selected_account =
        (first { $_->landing_company->social_responsibility_check && $_->landing_company->social_responsibility_check eq 'required' }
            @$closed_clients) // (first { !$_->is_virtual && LandingCompany::Registry::get_currency_type($_->currency) eq 'fiat' } @$closed_clients)
        // (first { !$_->is_virtual } @$closed_clients) // $closed_clients->[0];

    my $reason = $selected_account->status->closed->{reason} // '';
    $_->status->clear_disabled for @$closed_clients;

    BOM::Platform::Event::Emitter::emit(
        'account_reactivated',
        {
            loginid        => $selected_account->loginid,
            closure_reason => $reason
        });

    my $environment      = request()->login_env({user_agent => $c->req->headers->header('User-Agent')});
    my $unknown_location = !$selected_account->user->logged_in_before_from_same_location($environment);

    # perform postponed logging and notification
    $selected_account->user->after_login(undef, $environment, $app->{id});
    $c->c($selected_account, $unknown_location, $app);
}

=head2 is_login_suspended

Returns true if login is suspended

Arguments:

=over 4

=item C<loginid>

Loginid of the client

=back

=cut

sub is_login_suspended {
    my $loginid = shift;

    return 1 if BOM::Config::Runtime->instance->app_config->system->suspend->all_logins;

    return 1 if ($loginid and grep { $loginid =~ /^$_/ } @{BOM::Config::Runtime->instance->app_config->system->suspend->logins});

    return 0;
}

=head2 get_oneall_like_provider_data

#To integrate with oneall, we need to have $provider_data object with uid
#So we'll rely on 'sls_email' as uid for social login.

=cut

sub get_oneall_like_provider_data {
    my ($email, $provider) = @_;
    return {
        user => {
            identity => {
                provider              => $provider,
                provider_identity_uid => "sls_$email"
            }}};
}

1;
