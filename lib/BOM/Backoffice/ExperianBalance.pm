package BOM::Backoffice::ExperianBalance;
use strict;
use warnings;

use Mojo::UserAgent;
use Mojo::UserAgent::CookieJar;

my $urls = {
    login_page   => 'https://proveid.experian.com/signin/',
    login_post   => 'https://proveid.experian.com/signin/onsignin.cfm',
    logoff_page  => 'https://proveid.experian.com/signin/signoff.cfm',
    balance_page => 'https://proveid.experian.com/preferences/index.cfm',

};
my $ua = Mojo::UserAgent->new->cookie_jar(Mojo::UserAgent::CookieJar->new);

sub _get_csrf {
    my $dom = shift // $ua->get($urls->{login_page})->result->dom;
    return $dom->at('input[name=_CSRF_token]')->attr('value');
}

sub get_balance {
    my ($login, $password) = @_;
    my $csrf = _get_csrf();
    my $tx   = $ua->post(
        $urls->{login_post} => form => {
            _CSRF_token => $csrf,
            login       => $login,
            password    => $password,
            btnSubmit   => 'Login'
        });
    unless (my $res = $tx->success) {
        my $err = $tx->error;
        die "$err->{code} response: $err->{message}" if $err->{code};
        die "Connection error: $err->{message}";
    }

    my $page = $ua->get($urls->{balance_page})->result->dom;
    $ua->get($urls->{logoff_page});

    my $r = $page->find('[ResultList clearfix]')->map('text')->join("");
    (my $used)  = $r =~ /Credits Used: (\d+)/;
    (my $limit) = $r =~ /Credits Limit: (\d+)/;
    return ($used, $limit);
}

1;
