#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More (tests => 2);
use Test::Exception;
use Test::NoWarnings;

use Date::Utility;

use BOM::System::Host;
use BOM::Platform::Runtime;
subtest 'BOM::System::Host basic tests' => sub {

    lives_ok {
        my $host = BOM::System::Host->new({
            name           => 'fred',
            canonical_name => 'tierpoint-fred',
            ip_address     => '1.2.3.4',
            roles          => ['streaming_server', 'loggedout_server'],
            roles          => ['streaming_server', 'ui_server'],
            birthdate      => Date::Utility->new->iso8601,
        });
    }
    'Able to instantiate a BOM::System::Host manually';

    throws_ok {
        my $host = BOM::System::Host->new({
            name           => 'fred',
            canonical_name => 'tierpoint-fred',
            ip_address     => '1.2.3.4.5',
            roles          => ['streaming_server', 'ui_server'],
        });
    }
    qr/Attribute \(ip_address\) does not pass/, 'Invalid IP address is rejected';

    throws_ok {
        my $host = BOM::System::Host->new({
            canonical_name => 'tierpoint-fred',
            ip_address     => '1.2.3.4',
            roles          => ['streaming_server', 'ui_server'],
        });
    }
    qr/Attribute \(name\) is required/, 'name is required';

    throws_ok {
        my $host = BOM::System::Host->new({
            name           => 'fred',
            canonical_name => 'tierpoint-fred',
            roles          => ['streaming_server', 'ui_server'],
        });
    }
    qr/Attribute \(ip_address\) is required/, 'ip_address is required';

    throws_ok {
        my $host = BOM::System::Host->new({
            name             => 'fred',
            ip_address       => '123.123.22.11',
            canonical_name   => 'tierpoint-fred',
            role_definitions => BOM::Platform::Runtime->instance->host_roles,
            roles            => ['fribitz'],
        });
    }
    qr/Unknown BOM::System::Host::Role fribitz/, 'Cannot instantiate with an unregistered BOM::System::Host::Role';

    my $host = BOM::System::Host->new({
        name             => 'fred',
        ip_address       => '1.2.3.4',
        role_definitions => BOM::Platform::Runtime->instance->host_roles,
        roles            => [BOM::Platform::Runtime->instance->host_roles->get('streaming_server')],
        groups           => ['rmg', 'bom'],
    });

    is($host->canonical_name,  'fred',                              'Canonical name defaults to name');
    is($host->domain,          'regentmarkets.com',                 'Internal domain is regentmarkets.com');
    is($host->external_domain, 'binary.com',                        'External domain is binary.com');
    is($host->fqdn,            'fred.regentmarkets.com',            'Internal fqdn is fred.regentmarkets.com');
    is($host->external_fqdn,   'fred.binary.com',                   'External fqdn is fred.binary.com');
    is(1,                      $host->has_role('streaming_server'), 'Host has streaming_server role');
    is(undef,                  $host->has_role('fribitz_server'),   'Host does not have fribitz_server role');
    is(1,                      $host->belongs_to('rmg'),            'Host belongs to rmg group');
    is(1, $host->belongs_to('rmg', 'foo'), 'Host belongs to rmg group in multi-value (one match) context');
    is(1, $host->belongs_to('rmg', 'bom'), 'Host belongs to rmg group in multi-value (multi-match) context');
    is(undef, $host->belongs_to('foo'), 'Host does not belong to foo group');
    is('/etc/rmg/hosts.yml', BOM::Platform::Runtime->instance->hosts->config_file, 'Correct default location of hosts.yml file');

    $host = BOM::System::Host->new({
        name            => 'joe',
        ip_address      => '1.2.3.4',
        domain          => 'localdomain',
        external_domain => 'example.com',
    });
    is($host->domain,          'localdomain',     'Internal domain ok');
    is($host->external_domain, 'example.com',     'External domain ok');
    is($host->fqdn,            'joe.localdomain', 'Internal fqdn ok');
    is($host->external_fqdn,   'joe.example.com', 'External fqdn ok');
};
