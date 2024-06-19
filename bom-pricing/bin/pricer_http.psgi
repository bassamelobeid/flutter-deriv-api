use strict;
use warnings;

use JSON::MaybeXS;
use Plack::Request;
use Syntax::Keyword::Try;
use BOM::Pricing::v4::PricingEndpoint;
use BOM::Platform::Context qw (localize);
use DataDog::DogStatsd::Helper qw/stats_inc stats_count/;
use Log::Any qw($log);

my $json = JSON::MaybeXS->new;

my $root = sub {
    my $req = Plack::Request->new(shift);
    my (undef, $version, $currency, $shortcode) = split '/', $req->path;

    if ($version ne 'v1') {
        return [
            404,
            ['Content-Type' => 'application/json'],
            [ $json->encode({ error => "Not Found. Try /v1/:currency/:shortcode" }) ],
        ];
    } elsif (!$currency || !$shortcode) {
        return [
            400,
            ['Content-Type' => 'application/json'],
            [ $json->encode({ error => "Invalid endpint. Try /v1/:currency/:shortcode" }) ],
        ];
    }
     
    my $response;
    try {
        my $endpint = BOM::Pricing::v4::PricingEndpoint->new({
            shortcode => $shortcode,
            currency => $currency
        });
        $response = $endpint->get();
        stats_inc(
            'pricer_http.success', { tags => [
                'bet_type:' . $endpint->parameters->{bet_type},
                'underlying:' . $endpint->parameters->{underlying}
            ] }
        );
    } catch {
        my $e = $@;
        $response = ref($e) eq 'HASH' ? $e : {
            error => 'Unknown',
            details => $e
        };
        if($response->{error} eq 'Unknown') {
            $log->warnf('%s', $e);
        }
        stats_inc(
            'pricer_http.failure',
            {tags => ['error:' . $response->{error}]}
        );
    }

    return [
        exists $response->{error} ? 400 : 200,
        ['Content-Type' => 'application/json'],
        [ $json->encode($response) ],
    ];
};



use Plack::Builder;
builder {
    mount "/" => $root;
};
