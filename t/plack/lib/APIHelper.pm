package APIHelper;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK =
    qw(request auth_request decode_json deposit withdrawal_validate create_payout update_payout balance new_client record_failed_withdrawal);

use Encode;
use FindBin qw/$Bin/;
use Test::More;
use Plack::Test;
use Plack::Util;
use URI;
use JSON::MaybeXS ();
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
    __request($req);
}

sub __request {
    my $req = shift;
    test_psgi
        app    => $app,
        client => sub { shift->($req) };
}

sub decode_json {
    eval { JSON::MaybeXS->new->decode(Encode::decode_utf8($_[0])) };
}

=head2

deposit and deposit_validate request helper.

=cut

sub deposit {
    my %override    = @_;
    my $is_validate = delete $override{'is_validate'};
    my $url         = '/transaction/payment/doughflow/deposit';
    $url .= '_validate' if $is_validate;
    my $method  = $is_validate ? 'GET' : 'POST';                           # validate only support GET
    my $headers = $is_validate ? {}    : {'Content-Type' => 'text/xml'};
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

=pod

withdrawal_validate request helper.

=cut

sub withdrawal_validate {
    my %override = @_;
    request(
        'GET',
        '/transaction/payment/doughflow/withdrawal_validate',
        {
            amount            => 1,
            client_loginid    => delete $override{loginid},
            created_by        => 'derek',
            currency_code     => 'USD',
            fee               => 0,
            ip_address        => '127.0.0.1',
            payment_processor => 'WebMonkey',
            %override,
        });
}

=pod

balance request helper.

=cut

sub balance {
    my $loginid  = shift;
    my %override = (shift // {})->%*;
    my $r        = request(
        'GET',
        '/account',
        {
            client_loginid => $loginid,
            currency_code  => 'USD',
            %override,
        });
    my $account = decode_json($r->content);

    return $account->{balance} * 1.0;
}

=pod

create_payout request helper

=cut

sub create_payout {
    my %override = @_;
    request(
        'POST',
        '/transaction/payment/doughflow/create_payout',
        {
            amount         => 1,
            client_loginid => delete $override{loginid},
            siteid         => 1,
            created_by     => 'derek',
            currency_code  => 'USD',
            trace_id       => 123,
            ip_address     => '127.0.0.1',
            payment_method => 'WebMonkey',
            %override,
        },
        {'Content-Type' => 'text/xml'});
}

=pod

update_payout request helper.

=cut

sub update_payout {
    my %override = @_;
    request(
        'POST',
        '/transaction/payment/doughflow/update_payout',
        {
            amount            => 1,
            client_loginid    => delete $override{loginid},
            siteid            => 1,
            created_by        => 'derek',
            currency_code     => 'USD',
            trace_id          => 123,
            ip_address        => '127.0.0.1',
            payment_processor => 'WebMonkey',
            %override,
        },
        {'Content-Type' => 'text/xml'});
}

=head2 record_failed_withdrawal

A helper for record_failed_withdrawal POST request.

It takes the following named params:

=over 4

=item * C<client_loginid>, the loginid of the client

=item * C<error_desc>, the error description

=item * C<error_code>, the error code

=back

Returns,
    the request itself

=cut

sub record_failed_withdrawal {
    my %override = @_;
    request(
        'POST',
        '/transaction/payment/doughflow/record_failed_withdrawal',
        {
            accountidentifier => "470010:1******584",
            amount            => "10.02",
            client_loginid    => delete $override{client_loginid},
            error_code        => delete $override{error_code},
            error_desc        => delete $override{error_desc},
            frontendname      => "Binary (CR) SA USD",
            siteid            => 2,
            %override,
        },
        {'Content-Type' => 'text/xml'});
}

1;
