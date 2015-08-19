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
        is $request->website->name, 'Devbin';
        is $request->domain_name, 'deal01.devbin.io';
        is $request->language,    'EN';
        is $request->broker->code,                 'CR';
        is $request->real_account_broker->code,    'CR';
        is $request->virtual_account_broker->code, 'VRTC';
        ok !$request->from_ui, 'Not from ui';
    };

    subtest 'with country code' => sub {
        subtest 'country => Australia' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'au');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                'Devbin';
            is $request->broker->code,                 'CR';
            is $request->real_account_broker->code,    'CR';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'country => Indonesia' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'id');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                'Devbin';
            is $request->broker->code,                 'CR';
            is $request->real_account_broker->code,    'CR';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'country => UK' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'gb');
            is $request->broker_code, 'MX';
            is $request->language,    'EN';
            is $request->website->name,                'Devbin';
            is $request->broker->code,                 'MX';
            is $request->real_account_broker->code,    'MX';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'country => Netherlands' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'nl');
            is $request->broker_code, 'MLT';
            is $request->language,    'EN';
            is $request->website->name,                'Devbin';
            is $request->broker->code,                 'MLT';
            is $request->real_account_broker->code,    'MLT';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'country => France' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'fr');
            is $request->broker_code, 'MF';
            is $request->language,    'EN';
            is $request->website->name,                'Devbin';
            is $request->broker->code,                 'MF';
            is $request->real_account_broker->code,    'MF';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'country => Malta' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'mt');
            is $request->broker_code, undef;
            is $request->language,    'EN';
            is $request->website->name, 'Devbin';
            is $request->broker, undef;
            is $request->real_account_broker, undef;
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'country => US' => sub {
            my $request = BOM::Platform::Context::Request->new(country_code => 'us');
            is $request->broker_code, undef;
            is $request->language,    'EN';
            is $request->website->name, 'Devbin';
            is $request->broker, undef;
            is $request->real_account_broker, undef;
            is $request->virtual_account_broker->code, 'VRTC';
        };
    };

    subtest 'with country code, loginid' => sub {
        subtest 'loginid => CR10001' => sub {
            my $request = BOM::Platform::Context::Request->new(loginid => 'CR10001', country_code => 'au');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                'Devbin';
            is $request->broker->code,                 'CR';
            is $request->real_account_broker->code,    'CR';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'loginid => MLT10001' => sub {
            my $request = BOM::Platform::Context::Request->new(loginid => 'MLT10001', country_code => 'nl');
            is $request->broker_code, 'MLT';
            is $request->language,    'EN';
            is $request->website->name,                'Devbin';
            is $request->broker->code,                 'MLT';
            is $request->real_account_broker->code,    'MLT';
            is $request->virtual_account_broker->code, 'VRTC';
        };
    };

    subtest 'with domain name' => sub {
        subtest 'domain_name => cr-deal01.binary.com' => sub {
            my $request = BOM::Platform::Context::Request->new(domain_name => 'cr-deal01.binary.com');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                'Binary';
            is $request->broker->code,                 'CR';
            is $request->real_account_broker->code,    'CR';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'domain_name => cr-deal01.devbin.io' => sub {
            my $request = BOM::Platform::Context::Request->new(domain_name => 'cr-deal01.devbin.io');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                'Devbin';
            is $request->broker->code,                 'CR';
            is $request->real_account_broker->code,    'CR';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'domain_name => cr-deal01.binaryqa01.com' => sub {
            my $request = BOM::Platform::Context::Request->new(domain_name => 'cr-deal01.binaryqa01.com');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                'Binaryqa01';
            is $request->broker->code,                 'CR';
            is $request->real_account_broker->code,    'CR';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'domain_name => cr-deal01.binaryqa02.com' => sub {
            my $request = BOM::Platform::Context::Request->new(domain_name => 'cr-deal02.binaryqa02.com');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                'Binaryqa02';
            is $request->broker->code,                 'CR';
            is $request->real_account_broker->code,    'CR';
            is $request->virtual_account_broker->code, 'VRTC';
        };

        subtest 'domain_name => cr-deal01.binaryqa03.com' => sub {
            my $request = BOM::Platform::Context::Request->new(domain_name => 'cr-deal02.binaryqa03.com');
            is $request->broker_code, 'CR';
            is $request->language,    'EN';
            is $request->website->name,                'Binaryqa03';
            is $request->broker->code,                 'CR';
            is $request->real_account_broker->code,    'CR';
            is $request->virtual_account_broker->code, 'VRTC';
        };
    };
};

subtest 'url_for' => sub {
    my $domain        = "https://www.devbin.io";
    my $request       = BOM::Platform::Context::Request->new();
    my $bo_static_url = BOM::Platform::Runtime->instance->app_config->cgi->backoffice->static_url;
    subtest 'simple' => sub {
        $request->website->config->set('static.url', 'https://static.devbin.io/');
        is $request->url_for('paymentagent_withdraw.cgi'), "https://www.devbin.io/d/paymentagent_withdraw.cgi?l=EN", "cgi";
        is $request->url_for('helloworld.cgi'),            "https://www.devbin.io/c/helloworld.cgi?l=EN",            "cached cgi";
        is $request->url_for('backoffice/my_account.cgi'), "https://deal01.devbin.io/d/backoffice/my_account.cgi",   "backoffice";
        is $request->url_for('/why-us'),                   "$domain/why-us?l=EN",                                    "frontend";
        is $request->url_for('images/pages/open_account/real-money-account.svg'),
            $request->website->config->get('static.url') . "images/pages/open_account/real-money-account.svg", "Static indexed image";

        is $request->url_for('temp/tridey.jpg'),      "https://deal01.devbin.io/temp/tridey.jpg", "temp";
        is $request->url_for('errors/500.html'),      "$domain/errors/500.html",                  "errors";
        is $request->url_for('EN_appcache.appcache'), "$domain/EN_appcache.appcache",             "appcache";
        is $request->url_for('/'),                    "$domain/?l=EN",                            "frontend /";
    };

    subtest 'with param' => sub {
        is $request->url_for('paymentagent_withdraw.cgi', {a => 'b'}), "$domain/d/paymentagent_withdraw.cgi?a=b&l=EN", "cgi";
        is $request->url_for('/why-us', {login => 'true'}), "$domain/why-us?login=true&l=EN", "frontend";
        is $request->url_for('/why-us', {login => 'true'}, {static => 1}, {internal_static => 1}), $bo_static_url . "why-us", "interal static";

    };

    subtest 'with domain_type' => sub {
        is $request->url_for('my_account.cgi', undef, {bo => 1}), "https://deal01.devbin.io/d/backoffice/my_account.cgi", "backoffice";

        is $request->url_for('/why-us', undef, {static => 1}, {internal_static => 1}), $bo_static_url . "why-us", "Force Static image";

        is $request->url_for('paymentagent_withdraw.cgi', undef, {dealing => 1}), "https://deal01.devbin.io/d/paymentagent_withdraw.cgi?l=EN",
            "Dealing cgi";
        is $request->url_for('why-us', undef, {dealing => 1}), "https://deal01.devbin.io/why-us?l=EN", "Dealing frontend";

        is $request->url_for('/push/price/12345', undef, {no_lang => 1}), "https://www.devbin.io/push/price/12345", "Stream URL";
        is $request->url_for('push/price/12345',  undef, {no_lang => 1}), "https://www.devbin.io/push/price/12345", "Stream URL";
    };

    subtest 'static urls' => sub {
        $request->website->config->set('static.url', 'https://static.devbin.io/');

        my $request = BOM::Platform::Context::Request->new();
        is $request->url_for('images/my_image.png'),  "https://static.devbin.io/images/my_image.png",  "image(png) static URL";
        is $request->url_for('images/my_image.jpeg'), "https://static.devbin.io/images/my_image.jpeg", "image(jpeg) static URL";
        is $request->url_for('images/my_image.jpg'),  "https://static.devbin.io/images/my_image.jpg",  "image(jpg) static URL";
        is $request->url_for('images/my_image.gif'),  "https://static.devbin.io/images/my_image.gif",  "image(gif) static URL";
        is $request->url_for('images/my_image.svg'),  "https://static.devbin.io/images/my_image.svg",  "image(svg) static URL";

        is $request->url_for('flash/my_flash.swf'), "https://static.devbin.io/flash/my_flash.swf", "flash(swf) URL";
        is $request->url_for('flash/my_flash.swf'), "https://static.devbin.io/flash/my_flash.swf", "flash(swf) URL 2";
        is $request->url_for('flash/my_flash.swf', undef, undef, {internal_static => 1}), $bo_static_url . "flash/my_flash.swf",
            "load internal flash swf";
        is $request->url_for('backoffice/my_logo.png', undef, undef, {internal_static => 1}), $bo_static_url . "backoffice/my_logo.png",
            "load backoffice image";
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
