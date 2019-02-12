package BOM::OAuth::OneAll;

use v5.10;
use Mojo::Base 'Mojolicious::Controller';
use WWW::OneAll;
use BOM::Config;
use BOM::Database::Model::UserConnect;
use BOM::User;
use BOM::Platform::Account::Virtual;
use Try::Tiny;
use URI::QueryParam;
use BOM::OAuth::Helper;
use BOM::Platform::Context qw(localize);
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::OAuth::Static qw(get_message_mapping);
use Locale::Codes::Country qw(code2country);
use Email::Valid;

sub callback {
    my $c = shift;
    # Microsoft Edge and Internet Exporer browsers have a drawback
    # in carrying parameters through responses. Hence, we are retrieving the token
    # from the stash.
    # For optimization reason, the URI should be contructed afterwards
    # checking for presence of connection token in request parameters.
    my $connection_token = $c->param('connection_token') // $c->_get_provider_token() // '';
    my $redirect_uri = $c->req->url->path('/oauth2/authorize')->to_abs;
    # Redirect client to authorize subroutine if there is no connection token provided
    return $c->redirect_to($redirect_uri) unless $connection_token;

    my $brand_name = BOM::OAuth::Helper->extract_brand_from_params($c->stash('request')->params) // $c->stash('brand')->name;

    unless ($brand_name) {
        $c->session(social_error => 'Invalid brand name.');
        return $c->redirect_to($redirect_uri);
    }

    my $oneall = WWW::OneAll->new(
        subdomain   => 'binary',
        public_key  => BOM::Config::third_party()->{"oneall"}->{public_key},
        private_key => BOM::Config::third_party()->{"oneall"}->{private_key},
    );

    my $data = try {
        return $oneall->connection($connection_token);
    };

    # redirect client to auth page for connection error or when we receive
    # bad status code from oneall, wrong pub/private keys can be a reason
    # for bad status code
    if (not $data or $data->{response}->{request}->{status}->{code} != 200) {
        $c->session(social_error => localize(get_message_mapping()->{NO_USER_IDENTITY}));
        stats_inc('login.oneall.connection_failure',
            {tags => ["brand:$brand_name", "status_code:" . $data->{response}->{request}->{status}->{code}]});
        return $c->redirect_to($redirect_uri);
    }

    my $provider_result = $data->{response}->{result};
    if ($provider_result->{status}->{code} != 200 or $provider_result->{status}->{flag} eq 'error') {
        $c->session(social_error => localize(get_message_mapping()->{NO_AUTHENTICATION}));
        return $c->redirect_to($redirect_uri);
    }

    my $provider_data = $provider_result->{data};
    my $email         = _get_email($provider_data);
    my $provider_name = $provider_data->{user}->{identity}->{provider};

    # Check that whether user has granted access to a valid email address in her/his social account
    unless ($email and Email::Valid->address($email)) {
        $c->session(social_error => localize(get_message_mapping()->{INVALID_SOCIAL_EMAIL}, ucfirst $provider_name));
        return $c->redirect_to($redirect_uri);
    }

    my $user = try {
        BOM::User->new(email => $email)
    };
    my $user_connect = BOM::Database::Model::UserConnect->new;
    if ($user) {
        # Registered users who have email/password based account are forbidden
        # from social signin. As only one login method
        # is allowed (either email/password or social login).
        unless ($user->{has_social_signup}) {
            $c->session(social_error => localize(get_message_mapping()->{NO_LOGIN_SIGNUP}));
            return $c->redirect_to($redirect_uri);
        }

        my $user_providers = $user_connect->get_connects_by_user_id($user->{id});
        # Social user with a specific email can only sign up/sign in via the provider (social account)
        # by which s/he has created an account at the beginning.
        # Getting the first provider from $user_providers is based on the assumption that
        # there is exactly one provider for a social user.
        if ($provider_name ne $user_providers->[0]) {
            $c->session(social_error => localize(get_message_mapping()->{INVALID_PROVIDER}, ucfirst $user_providers->[0]));
            return $c->redirect_to($redirect_uri);
        }
    } else {
        # Get client's residence automatically from cloudflare headers
        my $residence = $c->stash('request')->country_code;
        # Create virtual client if user not found
        my $account = $c->__create_virtual_account(
            email              => $email,
            brand              => $brand_name,
            residence          => $residence,
            date_first_contact => $c->session('date_first_contact'),
            signup_device      => $c->session('signup_device'));
        if ($account->{error}) {
            my $error_msg =
                ($account->{error} eq 'invalid residence')
                ? localize(get_message_mapping()->{INVALID_RESIDENCE}, code2country($residence))
                : localize(get_message_mapping()->{$account->{error}});
            $c->session(social_error => $error_msg);
            return $c->redirect_to($redirect_uri);
        } else {
            $user = $account->{user};
        }

        # connect oneall provider data to user identity
        $user_connect->insert_connect($user->{id}, $provider_data);
        # initialize user_id and link account to social login.
        stats_inc('login.oneall.new_user_created', {tags => ["brand:$brand_name", "provider:$provider_name"]});
    }

    # login client to the system
    $c->session(_oneall_user_id => $user->{id});
    stats_inc('login.oneall.success', {tags => ["brand:$brand_name"]});
    return $c->redirect_to($redirect_uri);
}

# simple redirect since .html does not support POST from oneall
sub redirect {
    my $c                = shift;
    my $dir              = $c->param('dir') // '';
    my $connection_token = $c->param('connection_token') // $c->_get_provider_token() // '';

    return $c->redirect_to($dir . '?connection_token=' . $connection_token);
}

sub _get_provider_token {
    my $c = shift;

    my $request = URI->new($c->{stash}->{request}->{mojo_request}->{content}->{headers}->{headers}->{referer}[0]);

    return $request->query_param('provider_connection_token');
}

sub _get_email {
    my ($provider_data) = @_;

    # for Google
    my $emails = $provider_data->{user}->{identity}->{emails};
    return $emails->[0]->{value};    # or need check is_verified?
}

=head2 __create_virtual_account

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

sub __create_virtual_account {
    my ($c, %user_details) = @_;

    my $details = {
        email             => $user_details{email},
        client_password   => rand(999999),               # random password so you can't login without password
        has_social_signup => 1,
        brand_name        => $user_details{brand},
        residence         => $user_details{residence},
    };

    $details->{date_first_contact} = $user_details{date_first_contact} if $user_details{date_first_contact};
    $details->{signup_device}      = $user_details{signup_device}      if $user_details{signup_device};

    return BOM::Platform::Account::Virtual::create_account({details => $details});
}

1;
