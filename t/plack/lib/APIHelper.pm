package APIHelper;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw( request auth_request decode_json deposit withdraw balance new_client);

use FindBin qw/$Bin/;
use Test::More;
use Plack::Test;
use Plack::Util;
use URI;
use JSON ();
use HTTP::Headers;
use HTTP::Request;
use Digest::MD5 qw/md5_hex/;
use Digest::SHA qw/sha256_hex/;
use Data::Dumper;
use MIME::Base64;

if ($ENV{SKIP_TESTDB_INIT}) {
    ok(1, 'Note: Continuing with unchanged Test Database');
} else {
    require BOM::Test::Data::Utility::UnitTestDatabase;
    BOM::Test::Data::Utility::UnitTestDatabase->import(':init');
    ok(1, 'Test Database has been reset');
}

# To run the test-suite much faster, and distinguish test output from server output,
# and avoid server start-up overhead, run the test-suite and plack-server as distinct processes:
# PLACK_SERVER=Standalone plackup -r -l :88 paymentapi.psgi
# PLACK_TEST_IMPL=ExternalServer PLACK_TEST_EXTERNALSERVER_URI=http://127.0.0.1:88 prove -v t/plack/*.t

$ENV{PLACK_TEST_IMPL} ||= "Server";
$ENV{PLACK_SERVER}    ||= "HTTP::Server::PSGI";
$ENV{PLACK_ENV}       ||= "deployment";

my $app;
unless ($ENV{PLACK_TEST_IMPL} eq 'ExternalServer') {
    $app = Plack::Util::load_psgi($ENV{PAYMENT_PSGI} || "$Bin/../../paymentapi.psgi");
}

my $clear_password = '123456';    # this is the unencrypted pwd of CR011 in the test database.

sub request {
    my ($method, $url, $query_form, $headers) = @_;

    my $uri = URI->new($url);
    $uri->query_form($query_form) if $query_form;

    $headers ||= {};
    $headers->{'X-BOM-DoughFlow-Authorization'} ||= __df_auth_header();

    my $req = HTTP::Request->new($method, $uri, HTTP::Headers->new(%$headers));
    # printf STDERR 'req is %s', Dumper($req);
    __request($req);
}

sub __df_auth_header {
    my $time = time();
    my $hash = md5_hex($time . 'N73X49dS6SmX9Tf4');
    $hash = substr($hash, length($hash) - 10, 10);
    return join(':', $time, $hash);
}

sub auth_request {
    my ($method, $url, $query_form, $headers) = @_;

    my $uri = URI->new($url);
    $uri->query_form($query_form) if $query_form;

    $headers    ||= {};
    $query_form ||= {};
    my $user = delete $query_form->{user} || $query_form->{client_loginid};
    my $pass = delete $query_form->{pass} || $clear_password;
    $headers->{Authorization} = 'Basic ' . encode_base64($user . ':' . $pass, '');

    my $req = HTTP::Request->new($method, $uri, HTTP::Headers->new(%$headers));
    # printf STDERR 'req is %s', Dumper($req);
    __request($req);
}

sub __request {
    my $req = shift;
    test_psgi
        app    => $app,
        client => sub { shift->($req) };
}

sub decode_json {
    eval { JSON::decode_json($_[0]) };
}

## common
sub deposit {
    my %override    = @_;
    my $is_validate = delete $override{'is_validate'};
    my $url         = '/transaction/payment/doughflow/deposit';
    $url .= '_validate' if $is_validate;
    my $method = $is_validate ? 'GET' : 'POST';    # validate only support GET
    my $headers = $is_validate ? {} : {'Content-Type' => 'text/xml'};
    # note.. we have declared content-type xml but we are failing to build xml into the body!
    # These request parameters get sent as uri query strings.  That works ok for now but does not
    # really simulate how doughflow sends requests!   TODO:  build xml into request body.
    request(
        $method, $url,
        {
            amount            => 1,
            client_loginid    => delete $override{loginid},
            created_by        => 'derek',
            currency_code     => 'USD',
            fee               => 0,
            ip_address        => '127.0.0.1',
            payment_processor => 'WebMonkey',
            transaction_id    => '9876543',
            $is_validate ? () : (trace_id => time),
            %override,
        },
        $headers
    );
}

sub withdraw {
    my %override    = @_;
    my $is_validate = delete $override{'is_validate'};
    my $url         = '/transaction/payment/doughflow/withdrawal';
    $url .= '_validate' if $is_validate;
    my $method = $is_validate ? 'GET' : 'POST';    # validate only support GET
    my $headers = $is_validate ? {} : {'Content-Type' => 'text/xml'};
    request(
        $method, $url,
        {
            amount            => 1,
            client_loginid    => delete $override{loginid},
            created_by        => 'derek',
            currency_code     => 'USD',
            fee               => 0,
            ip_address        => '127.0.0.1',
            payment_processor => 'WebMonkey',
            $is_validate ? () : (trace_id => time),
            %override,
        },
        $headers
    );
}

sub balance {
    my ($loginid) = @_;
    my $r = request(
        'GET',
        '/account',
        {
            client_loginid => $loginid,
            currency_code  => 'USD',
        });
    my $account = decode_json($r->content);
    return $account->{balance};
}

1;
