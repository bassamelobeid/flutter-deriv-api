#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More (tests => 4);
use Test::Deep;
use Test::Exception;
use Test::NoWarnings;
use JSON qw(decode_json);
use Test::MockModule;

use Sys::Hostname;
use BOM::System::Host;
use BOM::Platform::Context::Request;
use BOM::Platform::Runtime;
my $hostname = hostname();

subtest 'build' => sub {
    subtest 'Defaults' => sub {
        my $request = BOM::Platform::Context::Request->new();
        is $request->broker_code, 'CR';
        like $request->website->name, '/^Binaryqa/';
        is $request->language, 'EN';
        is $request->broker->code,                   'CR';
        is $request->real_account_broker->code,      'CR';
        is $request->financial_account_broker->code, 'CR';
        is $request->virtual_account_broker->code,   'VRTC';
        ok !$request->from_ui, 'Not from ui';
    };

    subtest 'with country code' => sub {
        subtest 'country => Australia' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'au');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            like $request->website->name,                '/^Binaryqa/';
            is $request->broker->code,                   'CR';
            is $request->real_account_broker->code,      'CR';
            is $request->financial_account_broker->code, 'CR';
            is $request->virtual_account_broker->code,   'VRTC';
        };

        subtest 'country => Indonesia' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'id');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            like $request->website->name,                '/^Binaryqa/';
            is $request->broker->code,                   'CR';
            is $request->real_account_broker->code,      'CR';
            is $request->financial_account_broker->code, 'CR';
            is $request->virtual_account_broker->code,   'VRTC';
        };

        subtest 'country => UK' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'gb');
            is $request->broker_code, 'MX';
            is $request->language,    'EN';
            like $request->website->name,                '/^Binaryqa/';
            is $request->broker->code,                   'MX';
            is $request->real_account_broker->code,      'MX';
            is $request->financial_account_broker->code, 'MX';
            is $request->virtual_account_broker->code,   'VRTC';
        };

        subtest 'country => Netherlands' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'nl');
            is $request->broker_code, 'MLT';
            is $request->language,    'EN';
            like $request->website->name,                '/^Binaryqa/';
            is $request->broker->code,                   'MLT';
            is $request->real_account_broker->code,      'MLT';
            is $request->financial_account_broker->code, 'MF';
            is $request->virtual_account_broker->code,   'VRTC';
        };

        subtest 'country => France' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'fr');
            is $request->broker_code, 'MF';
            is $request->language,    'EN';
            like $request->website->name,                '/^Binaryqa/';
            is $request->broker->code,                   'MF';
            is $request->real_account_broker->code,      'MF';
            is $request->financial_account_broker->code, 'MF';
            is $request->virtual_account_broker->code,   'VRTC';
        };

        subtest 'country => Malta' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'mt');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            like $request->website->name,           '/^Binaryqa/';
            is $request->broker->code,              'CR';
            is $request->real_account_broker->code, 'CR';
            is $request->financial_account_broker, undef;
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'country => US' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'us');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            like $request->website->name,           '/^Binaryqa/';
            is $request->broker->code,              'CR';
            is $request->real_account_broker->code, 'CR';
            is $request->financial_account_broker, undef;
            is $request->virtual_account_broker->code, 'VRTC';
        };
    };

    subtest 'with country code, loginid' => sub {
        subtest 'loginid => CR10001' => sub {
            my $request = BOM::Platform::Context::Request->new(
                loginid      => 'CR10001',
                country_code => 'au'
            );
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            like $request->website->name,                '/^Binaryqa/';
            is $request->broker->code,                   'CR';
            is $request->real_account_broker->code,      'CR';
            is $request->financial_account_broker->code, 'CR';
            is $request->virtual_account_broker->code,   'VRTC';
        };

        subtest 'loginid => MLT10001' => sub {
            my $request = BOM::Platform::Context::Request->new(
                loginid      => 'MLT10001',
                country_code => 'nl'
            );
            is $request->broker_code, 'MLT';
            is $request->language,    'EN';
            like $request->website->name,                '/^Binaryqa/';
            is $request->broker->code,                   'MLT';
            is $request->real_account_broker->code,      'MLT';
            is $request->financial_account_broker->code, 'MF';
            is $request->virtual_account_broker->code,   'VRTC';
        };
    };

    subtest 'with domain name' => sub {
        subtest 'domain_name => cr-deal01.binary.com' => sub {
            my $request = BOM::Platform::Context::Request->new(domain_name => 'cr-deal01.binary.com');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                  'Binary';
            is $request->broker->code,                   'CR';
            is $request->real_account_broker->code,      'CR';
            is $request->financial_account_broker->code, 'CR';
            is $request->virtual_account_broker->code,   'VRTC';
        };

        subtest 'domain_name => www.binaryqa01.com' => sub {
            my $request = BOM::Platform::Context::Request->new(domain_name => 'www.binaryqa01.com');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                  'Binaryqa01';
            is $request->broker->code,                   'CR';
            is $request->real_account_broker->code,      'CR';
            is $request->financial_account_broker->code, 'CR';
            is $request->virtual_account_broker->code,   'VRTC';
        };
    };
};

subtest 'url_for' => sub {
    my $domain        = "https://www.binaryqa01.com";
    my $request       = BOM::Platform::Context::Request->new(domain_name => 'www.binaryqa01.com');
    my $bo_static_url = BOM::Platform::Runtime->instance->app_config->cgi->backoffice->static_url;
    subtest 'simple' => sub {
        $request->website->config->set('static.url', 'https://static.binaryqa01.com/');
        is $request->url_for('/why-us'), "$domain/why-us?l=EN", "frontend";
        is $request->url_for('images/pages/open_account/real-money-account.svg'),
            $request->website->config->get('static.url') . "images/pages/open_account/real-money-account.svg", "Static indexed image";

        is $request->url_for('errors/500.html'),      "$domain/errors/500.html",      "errors";
        is $request->url_for('EN_appcache.appcache'), "$domain/EN_appcache.appcache", "appcache";
        is $request->url_for('/'),                    "$domain/?l=EN",                "frontend /";
    };

    subtest 'with domain_type' => sub {
        like $request->url_for('my_account.cgi', undef, {bo => 1}), '/binaryqa.*\.com\/d\/backoffice\/my_account\.cgi/', "backoffice";

        like $request->url_for('paymentagent_withdraw.cgi', undef, {dealing => 1}), '/www.binaryqa\d+\.com\/d\/paymentagent_withdraw\.cgi\?l=EN/',
            "Dealing cgi";
    };

};

subtest 'langauage' => sub {
    my $request = BOM::Platform::Context::Request->new();
    is $request->language, 'EN', 'EN on default';

    $request = BOM::Platform::Context::Request->new(domain_name => 'binary.com');
    is $request->language, 'EN', 'EN on binary';

    BOM::Platform::Runtime->instance->app_config->cgi->allowed_languages(['EN', 'DE', 'JP']);

    $request = BOM::Platform::Context::Request->new(params => {l => 'en'});
    is $request->language, 'EN', 'en is accepted';

    $request = BOM::Platform::Context::Request->new(params => {l => 'EN'});
    is $request->language, 'EN', 'EN is also accepted';

    $request = BOM::Platform::Context::Request->new(params => {l => 'de'});
    is $request->language, 'DE', 'DE is accepted';

    $request = BOM::Platform::Context::Request->new(params => {l => 'zh'});
    is $request->language, 'EN', 'ZH is not accepted';
};
