use strict;
use warnings;

use BOM::RPC::v3::EmailVerification qw(email_verification);
use Test::Most;
use Email::Stuffer::TestLinks;
use Brands;
use Template;
use Template::AutoFilter;
use Test::MockModule;
use BOM::Platform::Context qw(localize request);
use BOM::RPC::v3::Utility;
use BOM::User;
use BOM::User::Client;

my $code             = 'RANDOM_CODE';
my $website_name     = 'My website name';
my $verification_uri = 'https://www.example.com/verify';
my $language         = 'EN';
my $source           = 1;
my $brand            = Brands->new(name => 'binary');
my $req              = BOM::Platform::Context::Request->new(
    brand_name => 'binary',
    language   => 'en'
);
request($req);

my $user_mocked = Test::MockModule->new('BOM::User');
$user_mocked->mock('clients', sub { bless {}, 'BOM::User::Client' });

sub get_verification_uri {
    my $action = shift;

    return "$verification_uri?action=$action&lang=$language&code=$code";
}

subtest 'Build Verification  URL' => sub {

    my $construct_expected_url = sub {
        my ($args, $extra_params, $action) = @_;
        if ($action eq 'payment_agent_withdraw') {
            my $expected_url = "$args->{verification_uri}?action=$action&lang=$args->{language}&code=$args->{code}&loginid=$args->{loginid}"
                . (
                defined $extra_params
                ? '&' . join '&', map { "$_=$extra_params->{$_}" } sort keys $extra_params->%*
                : ''
                );

            return $expected_url;
        }
        my $expected_url = "$args->{verification_uri}?action=$action&lang=$args->{language}&code=$args->{code}"
            . (
            defined $extra_params
            ? '&' . join '&', map { "$_=$extra_params->{$_}" } sort keys $extra_params->%*
            : ''
            );

        return $expected_url;
    };

    ## no utm params supplied
    my $args = {
        verification_uri => "http://www.fred.com",
        language         => 'Eng',
        code             => "Thisisthecode"
    };
    my $expected_url = $construct_expected_url->($args, undef, 'action_test');
    my $result       = BOM::RPC::v3::EmailVerification::_build_verification_url('action_test', $args);

    is($result, $expected_url, "url creation with no UTM params set correct");

    ## with utm params
    my $extra_params = {
        utm_source         => "google",
        utm_medium         => 'email',
        utm_campaign       => 'Grand_Opening',
        signup_device      => 'mobile',
        gclid_url          => 'adasd.sd',
        date_first_contact => '20150301',
        affiliate_token    => 'asdasd123',
    };
    $expected_url = $construct_expected_url->($args, $extra_params, 'action_test');
    $result       = BOM::RPC::v3::EmailVerification::_build_verification_url('action_test', {$args->%*, $extra_params->%*});

    is($result, $expected_url, "url creation with UTM params set correct");

    ## with extra utm params
    $extra_params = {
        utm_source       => "google",
        utm_medium       => 'email',
        utm_campaign     => 'summer-sale',
        utm_campaign_id  => 111017190001,
        utm_content      => '2017_11_09_O_TGiving_NoSt_SDTest_NoCoup_2',
        utm_term         => 'MyLink123',
        utm_ad_id        => 'f521708e-db6e-478b-9731-8243a692c2d5',
        utm_adgroup_id   => 45637,
        utm_gl_client_id => 3541,
        utm_msclk_id     => 5,
        utm_fbcl_id      => 6,
        utm_adrollclk_id => 7,
    };
    $args = {
        language         => 'Eng',
        code             => "Thisisthecode",
        verification_uri => "https://www.rover.com/search",
        loginid          => "CR90000001",
    };
    $expected_url = $construct_expected_url->($args, $extra_params, 'action_test');
    $result       = BOM::RPC::v3::EmailVerification::_build_verification_url('action_test', {$args->%*, $extra_params->%*});

    is($result, $expected_url, "url creation with extra UTM params set correctly");

    ## with extra payment_agent params
    $extra_params = {
        pa_amount   => 100,
        pa_loginid  => 'CR90000001',
        pa_currency => 'USD',
        pa_remarks  => 'Remarks'
    };
    $expected_url = $construct_expected_url->($args, $extra_params, 'payment_agent_withdraw');
    $result       = BOM::RPC::v3::EmailVerification::_build_verification_url('payment_agent_withdraw', {$args->%*, $extra_params->%*});

    is($result, $expected_url, "url creation with payment_agent params set correctly");

    # with invalid utm_params
    $extra_params = {
        utm_source       => "google",
        utm_medium       => '&email',
        utm_campaign     => 'summer-sale',
        utm_campaign_id  => 111017190001,
        utm_content      => '2017_11_09_O_TGiving_NoSt_SDTest_NoCoup_2',
        utm_term         => '^$%#MyLink123',
        utm_ad_id        => 'f521708e-db6e-478b-9731-8243a692c2d5',
        utm_adgroup_id   => 45637,
        utm_gl_client_id => 3541,
        utm_msclk_id     => 5,
        utm_fbcl_id      => 6,
        utm_adrollclk_id => 7,
    };

    my $valid_extra_params = {
        utm_source       => "google",
        utm_campaign     => 'summer-sale',
        utm_campaign_id  => 111017190001,
        utm_content      => '2017_11_09_O_TGiving_NoSt_SDTest_NoCoup_2',
        utm_ad_id        => 'f521708e-db6e-478b-9731-8243a692c2d5',
        utm_adgroup_id   => 45637,
        utm_gl_client_id => 3541,
        utm_msclk_id     => 5,
        utm_fbcl_id      => 6,
        utm_adrollclk_id => 7,
    };
    $expected_url = $construct_expected_url->($args, $valid_extra_params, 'invalid_utm_data');
    $result       = BOM::RPC::v3::EmailVerification::_build_verification_url('invalid_utm_data', {$args->%*, $extra_params->%*});

    is($result, $expected_url, "invalid UTM params are being skipped correctly");

    $extra_params = {redirect_to => 'derivx'};
    $expected_url = $construct_expected_url->($args, $extra_params, 'trading_platform_dxtrade_password_reset');
    $result = BOM::RPC::v3::EmailVerification::_build_verification_url('trading_platform_dxtrade_password_reset', {$args->%*, $extra_params->%*});

    is($result, $expected_url, "url params set correctly");
};

done_testing();
