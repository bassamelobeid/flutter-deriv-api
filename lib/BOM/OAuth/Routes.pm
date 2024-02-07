package BOM::OAuth::Routes;

use strict;
use warnings;

=head2 add_endpoints

Adds the endpoints supported to the routes. This is called from the main app.

=over 4 

=item *$r - the routes object

=back

=cut

sub add_endpoints {
    my ($r) = @_;
    $r->any('/authorize')->to('O#authorize');
    $r->any('/oneall/callback')->to('OneAll#callback');
    $r->any('/social-login/callback/app/:app_id'   => [id => qr/\d+/])->to('SocialLoginController#app_callback');
    $r->any('/social-login/callback/:sls_provider' => [id => qr/\w+/])->to('SocialLoginController#callback');
    $r->any('session/:service/sso')->to('SingleSignOn#authorize');
    $r->any('session/:service/authorize')->to('SingleSignOn#create');
    $r->any('session/thinkific/create')->to('Thinkific#create');
    $r->post('/api/v1/authorize')->to('RestAPI#authorize');
    $r->post('/api/v1/verify')->to('RestAPI#verify');
    $r->post('/api/v1/login')->to('RestAPI#login');
    $r->post('/api/v1/pta_login')->to('RestAPI#pta_login');

    #Bridge endpoint for mobile to fetch providers (social login service)
    $r->get('/api/v1/social-login/providers/:app_id')->to('SocialLoginController#get_providers');
    $r->get('/api/v1/pta_login/:one_time_token')->to('RestAPI#one_time_token');

    # microservices rest api authentication using oauth/api token
    $r->post('/api/v1/service/authorize')->to('RestAPI#authorize_services');

    # cTrader endpoints
    $r->post('/api/v1/ctrader/oauth2/crmApiToken')->to('CTrader#crm_api_token');
    $r->post('/api/v1/ctrader/oauth2/onetime/authorize')->to('CTrader#pta_login');
    $r->post('/api/v1/ctrader/oauth2/authorize')->to('CTrader#authorize');
    $r->post('/api/v1/ctrader/oauth2/onetime/generate')->to('CTrader#generate_onetime_token');

    # passkeys
    add_passkeys_endpoints($r);
}

=head2 add_passkeys_endpoints

Adds the passkeys endpoints to the current routes.

=over 4

=item *$r - the routes object

=back

=cut

sub add_passkeys_endpoints {
    my ($r) = @_;
    $r->get('/api/v1/passkeys/login/options')->to('PasskeysController#get_options');
    $r->post('/api/v1/passkeys/login/verify')->to('RestAPI#login');
}

1;
