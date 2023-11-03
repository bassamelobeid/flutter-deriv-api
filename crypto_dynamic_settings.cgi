#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::Backoffice::Auth;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Utility      qw(master_live_server_error);
use BOM::Backoffice::Sysinit      ();
BOM::Backoffice::Sysinit::init();

use BOM::Config;
use BOM::Cryptocurrency::BatchAPI;
use BOM::Cryptocurrency::DynamicSettings;
use HTML::Entities;
use JSON::MaybeUTF8 qw(decode_json_utf8);

PrintContentType();

BrokerPresentation('DYNAMIC SETTINGS MANAGEMENT');

my $batch = BOM::Cryptocurrency::BatchAPI->new();

my $request_params = request()->params;
my $action         = delete $request_params->{'action'};

if ($action && $action eq 'update_settings') {
    unless (grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}}) {
        print '<div id="message"><div id="error">' . master_live_server_error() . '</div></div><br />';
    } else {
        my $revision        = delete $request_params->{'revision'};
        my $update_settings = decode_json_utf8(delete $request_params->{'updated_settings'});

        my $settings = {};
        for my $key (keys %$update_settings) {
            $settings->{$key} = delete $request_params->{$key};
        }

        $batch->add_request(
            id     => 'save_dynamic_settings',
            action => 'config/save_dynamic_settings',
            body   => {
                revision   => $revision,
                settings   => $settings,
                staff_name => BOM::Backoffice::Auth::get_staffname(),
            },
        );
    }
}

$batch->add_request(
    id     => 'get_dynamic_settings',
    action => 'config/get_dynamic_settings',
    body   => {},
);

$batch->process();
my $response_bodies = $batch->get_response_body();

BOM::Cryptocurrency::DynamicSettings::render_save_dynamic_settings_response($response_bodies->{save_dynamic_settings},
    $response_bodies->{get_dynamic_settings})
    if $action && $action eq 'update_settings' && $response_bodies->{save_dynamic_settings};

my $settings = BOM::Cryptocurrency::DynamicSettings::normalize_settings_data($response_bodies->{get_dynamic_settings});
BOM::Backoffice::Request::template()->process(
    'backoffice/crypto_cashier/dynamic_settings.html.tt',
    {
        settings => $settings,
        title    => 'Crypto cashier settings',
    },
);

code_exit_BO();
