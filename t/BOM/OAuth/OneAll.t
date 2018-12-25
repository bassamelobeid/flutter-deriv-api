package t::BOM::OAuth::OneAll;

use Mojolicious::Lite;
use Test::More;
use Test::Mojo;
use Brands;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;
use BOM::OAuth::OneAll;
use BOM::Platform::Context qw(localize);
use BOM::OAuth::Static qw(get_message_mapping);
use Locale::Codes::Country qw(code2country);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

get '/callback' => sub {
    my $c = shift;

    my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => $c->req});
    BOM::Platform::Context::request($request);
    $c->stash(request => $request);

    my $email     = $c->param('email');
    my $brand     = $c->param('brand') || 'binary';
    my $residence = $c->stash('request')->country_code;
    my $one_all   = BOM::OAuth::OneAll->new($c);
    my $account   = $one_all->__create_virtual_account(
        email     => $email,
        brand     => $brand,
        residence => $residence
    );

    if ($account->{error}) {
        if ($account->{error} eq 'invalid residence') {
            $c->render(json => {'error' => localize(get_message_mapping()->{INVALID_RESIDENCE}, code2country($residence))});
        } else {
            $c->render(json => {'error' => localize(get_message_mapping()->{$account->{error}})});
        }
    } else {
        my @clients = $account->{user}->clients();
        $c->render(json => {'residence' => $clients[0]->residence});
    }

    #$c->render(text => $clients[0]->residence);
};

my $t;
subtest "check wether client's country of residence is set correctly" => sub {
    $t = Test::Mojo->new('t::BOM::OAuth::OneAll');
    my $residence;
    my $email;

    #Test case 1: valid residence
    $residence = 'au';
    $email     = 'test' . rand(999) . '@binary.com';
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });

    $t->get_ok("/callback?email=$email")->status_is(200)->json_is(json => {'residence' => $residence});

    #Test case 2: already registered user (email)
    $residence = 'es';
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });
    $t->get_ok("/callback?email=$email")->status_is(200)->json_is(json => {'error' => localize(get_message_mapping()->{'duplicate email'})});

    #Test case 3: invalid (restricted) residence
    $residence = 'my';
    $email     = 'test' . rand(999) . '@binary.com';
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });
    $t->get_ok("/callback?email=$email")->status_is(200)
        ->json_is(json => {'error' => localize(get_message_mapping()->{INVALID_RESIDENCE}, code2country($residence))});

    #Test case 4: invalid brand
    $residence = 'de';
    $email     = 'test' . rand(999) . '@binary.com';
    my $brand = 'invalid';
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });
    $t->get_ok("/callback?email=$email&brand=$brand")->status_is(200)
        ->json_is(json => {'error' => localize(get_message_mapping()->{'InvalidBrand'})});

};

done_testing();

1;
