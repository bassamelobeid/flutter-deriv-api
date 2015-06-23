#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More (tests => 5);
use Test::Deep;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use JSON qw(decode_json);

use Sys::Hostname;
use BOM::System::Host;
use BOM::Platform::Runtime;
use BOM::Platform::Context::Request;

subtest 'CR' => sub {
    subtest 'Default Country' => sub {
        my $request = BOM::Platform::Context::Request->new();
        is $request->broker->code, 'CR', 'CR broker';
        is_deeply([sort @{$request->available_currencies}], [qw(AUD EUR GBP USD)], 'available_currencies');
        is $request->country,          'Antarctica', 'We assume Antarctica as a default';
        is $request->default_currency, 'USD',        'Default currency is USD';
    };

    subtest 'EUR countries' => sub {
        foreach my $country_code (qw(fr dk de at be cz fi gr ie it lu nl pl se sk)) {
            my $request = BOM::Platform::Context::Request->new(country_code => $country_code);
            note $country_code;
            is $request->broker->code, 'MLT', 'broker for ' . $country_code;
            is_deeply([sort @{$request->available_currencies}], [qw(EUR GBP USD)], 'available_currencies');
            is $request->default_currency, 'EUR', 'default_currency';
        }
    };

    subtest 'AUD countries' => sub {
        foreach my $country_code (qw(au nz cx cc nf ki nr tv)) {
            my $request = BOM::Platform::Context::Request->new(country_code => $country_code);
            note $country_code;
            is $request->broker->code, 'CR', 'broker';
            is_deeply([sort @{$request->available_currencies}], [qw(AUD EUR GBP USD)], 'available_currencies');
            is $request->default_currency, 'AUD', 'default_currency';
        }
    };

    subtest 'GBP countries' => sub {
        foreach my $country_code (qw(gb uk)) {
            my $request = BOM::Platform::Context::Request->new(country_code => $country_code);
            note $country_code;
            is $request->broker->code, 'MX', 'broker';
            is_deeply([sort @{$request->available_currencies}], [qw(GBP USD)], 'available_currencies');
            is $request->default_currency, 'GBP', 'default_currency';
        }
    };
};

subtest 'MX' => sub {
    subtest 'Default Country' => sub {
        my $request = BOM::Platform::Context::Request->new(broker_code => 'MX');
        is_deeply([sort @{$request->available_currencies}], [qw(GBP USD)], 'available_currencies');
        is $request->default_currency, 'GBP', 'default_currency';
    };

    subtest 'Country Specific' => sub {
        foreach my $country_code (qw(fr dk de at be cz fi gr ie it lu li mc nl no pl se sk au nz cx cc nf ki nr tv gb uk)) {
            my $request = BOM::Platform::Context::Request->new(
                country_code => $country_code,
                broker_code  => 'MX'
            );
            note $country_code;
            is_deeply([sort @{$request->available_currencies}], [qw(GBP USD)], 'available_currencies');
            is $request->default_currency, 'GBP', 'default_currency';
        }
    };
};

subtest 'MLT' => sub {
    subtest 'Default Country' => sub {
        my $request = BOM::Platform::Context::Request->new(broker_code => 'MLT');
        is_deeply([sort @{$request->available_currencies}], [qw(EUR GBP USD)], 'available_currencies');
        is $request->default_currency, 'EUR', 'default_currency';
    };

    subtest 'EUR countries' => sub {
        foreach my $country_code (qw(fr dk de at be cz fi gr ie it lu li mc nl no pl se sk)) {
            my $request = BOM::Platform::Context::Request->new(
                country_code => $country_code,
                broker_code  => 'MLT'
            );
            note $country_code;
            is_deeply([sort @{$request->available_currencies}], [qw(EUR GBP USD)], 'available_currencies');
            is $request->default_currency, 'EUR', 'default_currency';
        }
    };

    subtest 'AUD countries' => sub {
        foreach my $country_code (qw(au nz cx cc nf ki nr tv)) {
            my $request = BOM::Platform::Context::Request->new(
                country_code => $country_code,
                broker_code  => 'MLT'
            );
            note $country_code;
            is_deeply([sort @{$request->available_currencies}], [qw(EUR GBP USD)], 'available_currencies');
            is $request->default_currency, 'EUR', 'default_currency';
        }
    };

    subtest 'GBP countries' => sub {
        foreach my $country_code (qw(gb uk)) {
            my $request = BOM::Platform::Context::Request->new(
                country_code => $country_code,
                broker_code  => 'MLT'
            );
            note $country_code;
            is_deeply([sort @{$request->available_currencies}], [qw(EUR GBP USD)], 'available_currencies');
            is $request->default_currency, 'GBP', 'default_currency';
        }
    };
};

subtest 'VRTC' => sub {
    subtest 'Default Country' => sub {
        my $request = BOM::Platform::Context::Request->new(broker_code => 'VRTC');
        is_deeply([sort @{$request->available_currencies}], [qw(USD)], 'available_currencies');
        is $request->default_currency, 'USD', 'default_currency';
    };

    subtest 'Country Specific' => sub {
        foreach my $country_code (qw(fr dk de at be cz fi gr ie it lu li mc nl no pl se sk au nz cx cc nf ki nr tv gb uk)) {
            my $request = BOM::Platform::Context::Request->new(
                country_code => $country_code,
                broker_code  => 'VRTC',
                domain_name  => 'binary.com'
            );
            note $country_code;
            is_deeply([sort @{$request->available_currencies}], [qw(USD)], 'available_currencies');
            is $request->default_currency, 'USD', 'default_currency';
        }
    };
};
