use strict;
use warnings;
use Test::More;
use Mojo::Message::Request;
use BOM::Platform::Context::Request;
use BOM::OAuth::Helper qw(request_details_string);

subtest "Request details string" => sub {
    my $request  = Mojo::Message::Request->new;
    my $ip       = '127.0.0.1';
    my $ua       = 'Chrome';
    my $referrer = 'Source webside';
    my $country  = 'country';
    $request->url->parse('http://example.com/path');
    $request->headers->header('User-Agent'       => $ua);
    $request->headers->header('Referer'          => $referrer);
    $request->headers->header('X-Client-Country' => $country);
    $request->headers->header('x-forwarded-for'  => $ip);         #there are other candidates.
    my $context = BOM::Platform::Context::Request::from_mojo({mojo_request => $request});
    my $result  = request_details_string($request, $context);
    like $result, qr/\/path/,    'Captured the path';
    like $result, qr/$ip/,       'Captured the IP';
    like $result, qr/$ua/,       'Captured the User-Agent';
    like $result, qr/$referrer/, 'Captured the Referrer';
    like $result, qr/$country/,  'Captured the Country';

};

done_testing();
