use strict;
use warnings;
use utf8;

use Test::More;
use Test::Exception;
use Test::MockModule;

use BOM::MyAffiliates::WebService;

subtest 'Instantiation' => sub {
    lives_ok {
        BOM::MyAffiliates::WebService->new(
            base_uri => 'http://go.YOURSITE.com/api',
            user     => "user",
            pass     => "pass"
        );
    }
    'Constructor work as expected';

    throws_ok {
        BOM::MyAffiliates::WebService->new;
    }
    qr/base_uri is required/, 'Constructor fails if base_uri is not passed';

    my $api = BOM::MyAffiliates::WebService->new(
        base_uri => 'http://go.YOURSITE.com/api',
        user     => "user",
        pass     => "pass"
    );
    is(ref $api, 'BOM::MyAffiliates::WebService', 'Instantiates correctly');

};

subtest 'Affiliate Registration' => sub {
    my $ua_mock = Test::MockModule->new('Net::Async::HTTP');

    $ua_mock->mock(
        'POST',
        sub {
            my ($self, $endpoint, $args) = @_;

            my $resp = 'valid';

            my $response = HTTP::Response->new(200);
            $response->content_type('text/plain');
            $response->add_content($resp);
            $response->content_length(length $response->content);

            return Future->done($response);
        });

    my $api = BOM::MyAffiliates::WebService->new(
        base_uri => 'http://go.YOURSITE.com/api',
        user     => "user",
        pass     => "pass"
    );

    my @mandatory_fields = (
        qw(PARAM_email PARAM_username PARAM_first_name PARAM_last_name PARAM_date_of_birth PARAM_individual PARAM_phone_number PARAM_city PARAM_state PARAM_website PARAM_agreement)
    );
    my %params = (
        PARAM_email         => 'something1@gmail.com',
        PARAM_username      => 'adalovelace',
        PARAM_first_name    => 'Ada',
        PARAM_last_name     => 'Lovelace',
        PARAM_date_of_birth => '1990-06-04',
        PARAM_individual    => 1,
        PARAM_whatsapp      => '12341234',
        PARAM_phone_number  => '12341234',
        PARAM_country       => 'AR',
        PARAM_city          => 'City',
        PARAM_state         => 'ST',
        PARAM_postcode      => '132423',
        PARAM_website       => 'www.google.com',
        PARAM_agreement     => 1
    );

    for my $f (@mandatory_fields) {
        my %t_params = %params;
        delete $t_params{$f};

        throws_ok {
            $api->register_affiliate(%t_params)->get;
        }
        qr/$f is required/, "Validate mandatory $f";

    }

    $params{Email} = 'mojtaba@domain.com ';

    my $identifier = $api->register_affiliate(%params)->get;

    ok($identifier, 'Register call return a new identifier');
    like($identifier, qr/\d*/, 'Identifier is an integer');

    $params{Username} = 'mk@google.com';
    $params{Email}    = 'mk@google.com';

    $identifier = $api->register_affiliate(%params)->get;

    ok($identifier, 'Email can also be username');
    like($identifier, qr/\d*/, 'Identifier is an integer as expected also');
};

done_testing;
