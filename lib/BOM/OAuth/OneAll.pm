package BOM::OAuth::OneAll;

use v5.10;

use Mojo::Base 'Mojolicious::Controller';
use WWW::OneAll;
use Syntax::Keyword::Try;
use URI::QueryParam;
use DataDog::DogStatsd::Helper qw( stats_inc );
use Locale::Codes::Country     qw( code2country );
use Email::Valid;

use BOM::Config;
use BOM::Database::Model::UserConnect;
use BOM::User;
use BOM::Platform::Account::Virtual;
use BOM::OAuth::Helper;
use BOM::Platform::Context qw( localize );
use BOM::OAuth::Static     qw( get_message_mapping );
use BOM::OAuth::Common;
use Log::Any qw($log);

sub callback {
    my $c = shift;
    # Microsoft Edge and Internet Exporer browsers have a drawback
    # in carrying parameters through responses. Hence, we are retrieving the token
    # from the stash.
    # For optimization reason, the URI should be contructed afterwards
    # checking for presence of connection token in request parameters.
    my $connection_token = $c->param('connection_token') // $c->_get_provider_token() // '';
    my $redirect_uri     = $c->req->url->path('/oauth2/authorize')->to_abs;
    # Redirect client to authorize subroutine if there is no connection token provided
    return $c->redirect_to($redirect_uri) unless $connection_token;

    my $brand_name = BOM::OAuth::Helper->extract_brand_from_params($c->stash('request')->params) // $c->stash('brand')->name;

    unless ($brand_name) {
        $c->session(social_error => localize(get_message_mapping()->{INVALID_BRAND}));
        return $c->redirect_to($redirect_uri);
    }

    try {
        my $oneall = WWW::OneAll->new(
            subdomain   => $brand_name,
            public_key  => BOM::Config::third_party()->{"oneall"}->{$brand_name}->{public_key},
            private_key => BOM::Config::third_party()->{"oneall"}->{$brand_name}->{private_key},
        );

        my $data = eval { $oneall->connection($connection_token); };

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
        my $email         = BOM::OAuth::Common::get_email_by_provider($provider_data);
        my $provider_name = $provider_data->{user}->{identity}->{provider} // '';

        # Check that whether user has granted access to a valid email address in her/his social account
        unless ($email and Email::Valid->address($email)) {
            $c->session(social_error => localize(get_message_mapping()->{INVALID_SOCIAL_EMAIL}, ucfirst $provider_name));
            return $c->redirect_to($redirect_uri);
        }

        my $user         = eval { BOM::User->new(email => $email) };
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
            if (defined $user_providers->[0] and $provider_name ne $user_providers->[0]) {
                $c->session(social_error => localize(get_message_mapping()->{INVALID_PROVIDER}, ucfirst $user_providers->[0]));
                return $c->redirect_to($redirect_uri);
            }

            #Remove social signup session if it exists and user is logging in
            delete $c->session->{_is_social_signup};
        } else {
            # Get client's residence automatically from cloudflare headers
            my $residence    = $c->stash('request')->country_code;
            my $user_details = {
                email              => $email,
                brand              => $brand_name,
                residence          => $residence,
                date_first_contact => $c->session('date_first_contact'),
                signup_device      => $c->session('signup_device'),
                myaffiliates_token => $c->session('myaffiliates_token'),
                gclid_url          => $c->session('gclid_url'),
                utm_medium         => $c->session('utm_medium'),
                utm_source         => $c->session('utm_source'),
                utm_campaign       => $c->session('utm_campaign'),
                source             => $c->param('app_id'),
            };
            my $utm_data = {
                utm_ad_id        => $c->session('utm_ad_id'),
                utm_adgroup_id   => $c->session('utm_adgroup_id'),
                utm_adrollclk_id => $c->session('utm_adrollclk_id'),
                utm_campaign_id  => $c->session('utm_campaign_id'),
                utm_content      => $c->session('utm_content'),
                utm_fbcl_id      => $c->session('utm_fbcl_id'),
                utm_gl_client_id => $c->session('utm_gl_client_id'),
                utm_msclk_id     => $c->session('utm_msclk_id'),
                utm_term         => $c->session('utm_term'),
            };

            # Create virtual client if user not found
            my $account = BOM::OAuth::Common::create_virtual_account($user_details, $utm_data);

            if ($account->{error}) {
                my $error_msg =
                    ($account->{error}->{code} eq 'invalid residence')
                    ? localize(get_message_mapping()->{INVALID_RESIDENCE}, code2country($residence))
                    : localize(get_message_mapping()->{$account->{error}});
                $c->session(social_error => $error_msg);
                return $c->redirect_to($redirect_uri);
            } else {
                $user = $account->{user};
                #User has used oneAll to signup
                $c->session(_is_social_signup => 1);
            }

            # connect oneall provider data to user identity
            $user_connect->insert_connect($user->{id}, $user->{email}, $provider_data);

            # track social signup on Segment
            my $utm_tags = {};

            foreach my $tag (qw( utm_source utm_medium utm_campaign gclid_url date_first_contact signup_device utm_content utm_term)) {
                $utm_tags->{$tag} = $c->session($tag) if $c->session($tag);
            }
            BOM::Platform::Event::Emitter::emit(
                'signup',
                {
                    loginid    => $account->{client}->loginid,
                    properties => {
                        type     => 'trading',
                        subtype  => 'virtual',
                        utm_tags => $utm_tags,
                    }});

            # initialize user_id and link account to social login.
            stats_inc('login.oneall.new_user_created', {tags => ["brand:$brand_name", "provider:$provider_name"]});
        }
# login client to the system
        $c->session(_oneall_user_id => $user->{id});
        stats_inc('login.oneall.success', {tags => ["brand:$brand_name"]});
        return $c->redirect_to($redirect_uri);
    } catch {
        stats_inc('login.oneall.error', {tags => ["brand:$brand_name"]});
        $c->session(social_error => localize(get_message_mapping()->{invalid}));
        return $c->redirect_to($redirect_uri);
    }
}

sub _get_provider_token {
    my $c = shift;

    my $request = URI->new($c->{stash}->{request}->{mojo_request}->{content}->{headers}->{headers}->{referer}[0]);

    return $request->query_param('provider_connection_token');
}

=head2 _delete_user

User delete request to oneall

=over 4

=item * C<brand_name> The brand name. This is either 'deriv' or 'binary'

=item * C<user_token> The user token of the user. This is fetched from users.binary_user_connects table

=back

Returns the result of the http request.

=cut

sub _delete_user {
    my ($brand_name, $user_token) = @_;
    my $res;
    try {
        my $oneall = WWW::OneAll->new(
            subdomain   => $brand_name,
            public_key  => BOM::Config::third_party()->{"oneall"}->{$brand_name}->{public_key},
            private_key => BOM::Config::third_party()->{"oneall"}->{$brand_name}->{private_key},
        );

        $res = $oneall->request('DELETE', "/users/" . $user_token, (query_params => ["confirm_deletion=true"]));
    } catch ($e) {
        $log->errorf('Failed to delete one all data for the user: %s', $e);
    }
    return $res;
}

=head2 anonymize_user

Anonymize the user from oneall

=over 4

=item * C<oneall_user_data> This contains the user's binary_user_id, oneall user_token and the provider (google, facebook etc)

=back

Retuns 1, if the anonymization is successful. 0 otherwise.

=cut

sub anonymize_user {
    my ($oneall_user_data) = @_;

    my $user_connect = BOM::Database::Model::UserConnect->new;
    my $count        = 0;
    for my $user_data (@$oneall_user_data) {
        my $res = _delete_user("deriv", $user_data->{user_token});
        # If the above request fails, check and delete if the user is in the binary sub domain
        if (exists $res->{response}->{request}->{status}->{code} && $res->{response}->{request}->{status}->{code} == 404) {
            $res = _delete_user("binary", $user_data->{user_token});
        }

        # if the request was successful then delete the binary_user_connects data
        if (exists $res->{response}->{request}->{status}->{code} && $res->{response}->{request}->{status}->{code} == 200) {
            $log->info("Removed oneall profile data for the user id: " . $user_data->{binary_user_id});
            $user_connect->remove_connect($user_data->{binary_user_id}, $user_data->{provider});
            $count++;
        }
    }
    return 1 if $count == scalar(@$oneall_user_data);
    return 0;
}

1;
