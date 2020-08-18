package BOM::OAuth::SingleSignOn;

use strict;
use warnings;

no indirect;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Parameters;

use URI;
use Path::Tiny;
use Format::Util::Strings qw( defang );
use Digest::SHA qw(hmac_sha256_hex);
use Syntax::Keyword::Try;
use Encode qw(encode);
use Log::Any qw($log);

use BOM::User::Client;
use BOM::Database::Model::OAuth;

# Developer disclaimer: we needed this fast

my %broker_mapping = (
    VRTC => '1',
    CR   => '2',
    MX   => '3',
    MF   => '4',
    MLT  => '5',
);

my @dictionary;

BEGIN {
    ## This is a list of "naughty" words with ROT-13 to obfuscate.
    ## Because you do NOT want to look at this list of words.
    my %bad_words = map { y/N-ZA-z/A-za-m/r => 1 } qw/
        nohfref  nohfvir  nqhygre  nveurnq  nzchgrr  ncrfuvg  nerbyne  nebhfny  nebhfrq  nebhfre
        nebhfrf  nfrkhny  nffurnq  nffubyr  ngurvfz  ngurvfg  nherbyn  nherbyr  onfgneq  ornaref
        orqnzaf  oribzvg  ovgpurq  ovgpurf  oybjwbo  obvaxrq  obaqntr  oernfgf  ohpxnff  ohssbba
        ohttref  ohttrel  pnepnff  prffcvg  puvaxvr  pubyren  pbaqbzf  pbbanff  pencbyn  pelonol
        phzzref  phzzvat  qnzavat  qrnqrfg  qrnqzna  qrnqzra  qrobjry  qrsvyre  qrsvyrf  qrzbavp
        qvpxref  qvcfuvg  qvegont  qvfrnfr  qbtfuvg  qhzonff  rarzngn  rebgvfz  rivyrfg  snttbgf
        snttbgl  snegvat  srfgref  svttvat  svfgvat  shpxref  shpxvat  shpxbss  shpxhcf  shpxjvg
        shaqvrf  trfgncb  tbqqnza  tbqyrff  uneqnff  uneybgf  unfvqvp  ungrshy  uryyobk  uryypng
        uryyqbt  uryyvfu  ubbxref  uhzcvat  vqvbgvp  vaprfgf  vafnare  wnpxnff  wrexvre  wvtnobb
        wvirnff  xvpxnff  xvyypbj  xvyywbl  xvffbss  yncpbpx  yrfovna  yrfvbaf  yvovqbf  yhpvsre
        yhangvp  zheqref  anxrqyl  avttref  avccyrf  alzcubf  betnfzf  cnagvrf  crttvat  cravfrf
        creireg  cvturnq  cvzcyrf  cvffnag  cvffref  cvffvat  cvffcbg  cynlobl  cbbsgnu  cbbsgre
        cbbcvat  cbgurnq  cerqnza  chffvre  chffvrf  dhrreyl  enpvfzf  enturnq  encnoyr  encrshy
        engsvax  engfuvg  erpghzf  ergneqf  eribzvg  evzzvat  fngnavp  fpuvmbf  fpuvmmb  fpuvmml
        fphzont  frkvrfg  frkvfgf  frkyrff  frkcreg  frkcbgf  funtont  fuvggrq  fulfgre  fynttre
        fyhggrq  fzrtznf  fcnfgvp  fgvaxre  fjvatre  grgnahf  gvggvrf  gbcyrff  gbegher  genvgbe
        gjvaxvr  htyvrfg  haobjry  hatbqyl  hcibzvg  intvanr  intvany  intvanf  ivzhfre  ibzvgrq
        ibzvgre  ibzvgbf  ibzvghf  jnaxref  jnaxvat  jrgonpx  jvfrnff
        /;
    @dictionary = grep { /^[a-z]{7}$/ && !exists $bad_words{$_} } path("/usr/share/dict/words")->lines_utf8({chomp => 1});
}

sub authorize {
    my $c = shift;

    my $service  = defang($c->stash('service'));
    my $auth_url = $c->req->url->path('/oauth2/authorize')->to_abs;

    my $app_id = defang($c->param('app_id'));
    my $app    = BOM::Database::Model::OAuth->new()->verify_app($app_id);

    if ($app && $app->{name} eq $service) {

        my %info = _verify_sso_request($c, $app);
        $c->session(%info);

        $auth_url->query(app_id => $app->{id});
        $c->redirect_to($auth_url);

    } else {
        my $brand_uri = Mojo::URL->new($c->stash('brand')->default_url);
        $c->redirect_to($brand_uri);
    }
}

sub create {
    my $c = shift;

    my $service = defang($c->stash('service'));
    my $app_id  = defang($c->param('app_id'));

    my $app = BOM::Database::Model::OAuth->new()->verify_app($app_id);

    if ($app && $app->{name} eq $service) {

        my $uri    = Mojo::URL->new($app->{verification_uri});
        my %params = _sso_params($c, $app);
        $uri->query(%params);

        $c->redirect_to($uri);
    }
}

sub _verify_sso_request {
    my ($c, $app) = @_;

    my ($payload, $sig) = map { defang($c->param($_)) // undef } qw/ sso sig /;

    if (hmac_sha256_hex($payload, $app->{secret}) eq $sig) {

        # Discourse sends the params as base64 URL encoded string
        if ($app->{name} eq 'discourse') {
            my $discourse_data = Mojo::Parameters->new()->parse(MIME::Base64::decode_base64($payload))->to_hash();
            return ('_sso_nonce' => $discourse_data->{nonce});
        }

    } else {
        $log->debugf("Can't verify %s sso request check the application secret", $app->{name});
    }

}

sub _sso_params {
    my ($c, $app) = @_;

    my $nonce = defang($c->param('nonce'));
    my $token = defang($c->param('token1'));

    my $loginid = BOM::Database::Model::OAuth->new()->get_token_details($token)->{loginid};

    my $client = BOM::User::Client->new({
        loginid      => $loginid,
        db_operation => 'replica'
    });

    if ($app->{name} eq 'discourse') {

        my ($fake_name) = _generate_pseudo_name($client->loginid);

        my $discourse_params = {
            nonce                    => $nonce,
            email                    => $client->user->email,
            external_id              => $client->binary_user_id,
            username                 => $fake_name->{username},
            name                     => $fake_name->{full_name},
            avatar_url               => '',
            bio                      => '',
            admin                    => 0,
            moderator                => 0,
            suppress_welcome_message => 0
        };

        my $payload = URI->new('', 'http');
        $payload->query_form(%$discourse_params);
        $payload = $payload->query;

        $payload = MIME::Base64::encode_base64(encode('UTF-8', $payload), '');
        my $sig = hmac_sha256_hex($payload, $app->{secret});

        return (
            sso => $payload,
            sig => $sig
        );
    }
}

sub _generate_pseudo_name {
    my $loginid = shift;

    if (@dictionary eq 0) {
        $log->warn("SingleSignOn random name generator name dictionary is empty!");
        return "";
    }

    my ($broker, $id) = $loginid =~ /([A-Z]+)([0-9]+)/;

    my @name;

    while ($id) {
        push @name, $dictionary[$id % 8192];
        $id = int($id / 8192);
    }
    push @name, ($broker_mapping{$broker} // '');

    return {
        username  => (join "-", @name),
        full_name => (join " ", @name),
    };
}

1;
