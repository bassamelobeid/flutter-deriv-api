#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::DynamicSettings;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );

use f_brokerincludeall;

use BOM::Config;
use BOM::Config::Runtime;
use HTML::Entities;
use Data::Compare;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();
use BOM::Backoffice::Utility qw(master_live_server_error);

PrintContentType();

BrokerPresentation('DYNAMIC SETTINGS MANAGEMENT');

my @all_settings = BOM::Config::Runtime->instance->app_config->all_keys();

my $settings_list = [];
if (request()->param('page') eq 'global') {
    my $group_to_display = request()->param('group');
    my $authorisations   = {
        shutdown_suspend => ['IT'],
        quant            => ['Quants'],
        it               => ['IT'],
        others           => ['IT'],
        payments         => ['IT'],
    };

    if ($authorisations->{$group_to_display} && BOM::Backoffice::Auth0::has_authorisation($authorisations->{$group_to_display})) {
        push @{$settings_list}, @{BOM::DynamicSettings::get_settings_by_group($group_to_display)};
    } else {
        print "Access restricted.";
        code_exit_BO();
    }
}

if (scalar @{$settings_list;} == 0) {
    print "<b>There is no setting in this Group!</b><br />Go to <a style=\"color:white\" href=\""
        . request()->url_for('backoffice/f_broker_login.cgi', {})
        . "#dynamic_settings\">Login Page</a> and try again";
    if (request()->param('group') eq 'others') {
        print
            "<br /><br /><b>We keep \"others\" group to show uncategorized settings, the reason that you can't see any settings in this page is beacuse there is no uncategorized setting left.</b>";
    }
    code_exit_BO();
}

my $submitted = request()->param('submitted');

if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
    print '<div id="message"><div id="error">' . master_live_server_error() . '</div></div><br />';
} else {
    BOM::DynamicSettings::save_settings({
        'settings'          => request()->params,
        'settings_in_group' => $settings_list,
        'save'              => request()->param('submitted'),
    });
}
my @send_to_template = ();

my ($all_settings, $title);
if (request()->param('page') eq 'global') {
    $all_settings = \@all_settings;
    my $sub_title = request()->param('group');
    $sub_title =~ s/\_/\ /g;
    $title = "GLOBAL DYNAMIC SETTINGS - " . $sub_title;
}

push @send_to_template,
    BOM::DynamicSettings::generate_settings_branch({
        settings          => $all_settings,
        settings_in_group => $settings_list,
        group             => request()->param('group'),
        title             => $title,
        submitted         => request()->param('page'),
    });

BOM::Backoffice::Request::template()->process(
    'backoffice/dynamic_settings.html.tt',
    {
        'settings' => \@send_to_template,
    });
code_exit_BO();
