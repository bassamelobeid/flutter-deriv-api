#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use Date::Utility;
use Digest::MD5 qw(md5_hex);
use HTML::Entities;
use JSON::MaybeXS;
use LandingCompany::Registry;
use List::Util qw(first);
use f_brokerincludeall;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::DynamicSettings;
use BOM::Platform::Config;
use BOM::Platform::RiskProfile;
use BOM::Platform::RiskProfile;
use BOM::Platform::Runtime;
use LandingCompany::Offerings;

BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new;

PrintContentType();
BrokerPresentation('Product Management');

my $staff            = BOM::Backoffice::Auth0::from_cookie()->{nickname};
my $r                = request();
my $limit_profile    = BOM::Platform::Config::quants->{risk_profile};
my $quants_config    = BOM::Platform::Runtime->instance->app_config->quants;
my %known_profiles   = map { $_ => 1 } keys %$limit_profile;
my %allowed_multiple = (
    market            => 1,
    submarket         => 1,
    underlying_symbol => 1,
    landing_company   => 1,
);

my $need_to_save = 0;

if ($r->param('update_limit')) {
    my @known_keys    = qw(contract_category market submarket underlying_symbol start_type expiry_type barrier_category landing_company);
    my $offerings_obj = LandingCompany::Offerings->get('costarica', BOM::Platform::Runtime->instance->get_offerings_config);
    my %known_values  = map { $_ => [$offerings_obj->values_for_key($_)] } @known_keys;
    # landing company is not part of offerings object.
    $known_values{landing_company} = [map { $_->short } LandingCompany::Registry::all()];
    my %ref;

    foreach my $key (@known_keys) {
        if (my $value = $r->param($key)) {
            if (first { $value =~ $_ } @{$known_values{$key}}) {
                # we should not allow more than one value for risk_profile
                code_exit_BO('You could not specify multiple value for ' . $key) if not $allowed_multiple{$key} and $value =~ /,/;
                $ref{$key} = $value;
            } else {
                code_exit_BO("Unrecognized value[" . encode_entities($r->param($key)) . "] for $key. Nothing is updated!!");
            }
        }
    }

    my $uniq_key = substr(md5_hex(sort { $a cmp $b } values %ref), 0, 16);

    # if we just want to add client into watchlist, custom conditions is not needed
    my $has_custom_conditions = keys %ref;
    if (my $custom_name = $r->param('custom_name')) {
        $ref{name} = $custom_name;
    } elsif ($has_custom_conditions) {
        code_exit_BO('Name is required.');
    }

    my $p = $r->param('risk_profile');
    if ($p and $known_profiles{$p}) {
        $ref{risk_profile} = $p;
    } elsif ($has_custom_conditions) {
        code_exit_BO('Unrecognize risk profile.');
    }

    if (my $id = $r->param('client_loginid')) {
        my $current = $json->decode($quants_config->custom_client_profiles);
        my $comment = $r->param('comment');
        $current->{$id}->{custom_limits}->{$uniq_key} = \%ref    if $has_custom_conditions;
        $current->{$id}->{reason}                     = $comment if $comment;
        $current->{$id}->{updated_by}                 = $staff;
        $current->{$id}->{updated_on}                 = Date::Utility->new->date;
        $quants_config->custom_client_profiles($json->encode($current));
    } else {
        my $current = $json->decode($quants_config->custom_product_profiles);
        $ref{updated_by}      = $staff;
        $ref{updated_on}      = Date::Utility->new->date;
        $current->{$uniq_key} = \%ref;
        $quants_config->custom_product_profiles($json->encode($current));
    }

    $need_to_save = 1;
}

if ($r->param('delete_limit')) {
    my $id = $r->param('id');
    code_exit_BO('ID is required. Nothing is deleted.') if not $id;

    if (my $client_loginid = $r->param('client_loginid')) {
        my $current = $json->decode($quants_config->custom_client_profiles);
        delete $current->{$client_loginid}->{custom_limits}->{$id};
        $quants_config->custom_client_profiles($json->encode($current));
    } else {
        my $current = $json->decode($quants_config->custom_product_profiles);
        delete $current->{$id};
        $quants_config->custom_product_profiles($json->encode($current));
    }
    $need_to_save = 1;
}

if ($r->param('delete_client')) {
    my $client_loginid = $r->param('client_loginid');
    my $current        = $json->decode($quants_config->custom_client_profiles);
    delete $current->{$client_loginid};
    $quants_config->custom_client_profiles($json->encode($current));
    $need_to_save = 1;
}

if ($r->param('update_otm')) {
    code_exit_BO('Must specify either underlying symbol/market and otm value to set custom OTM threshold')
        unless ($r->param('underlying_symbol') or $r->param('market'))
        and $r->param('otm_value');

    code_exit_BO('Maximum value of OTM threshold is 1.') if $r->param('otm_value') > 1;

    my $current = $json->decode($quants_config->custom_otm_threshold);

    # underlying symbol supercedes market
    my $which = $r->param('underlying_symbol') ? 'underlying_symbol' : 'market';
    my @common_inputs = qw(expiry_type is_atm_bet);
    foreach my $key (map { my $input = $_; $input =~ s/\s+//; $input } split ',', $r->param($which)) {
        my $string = join '', map { $r->param($_) } grep { $r->param($_) ne '' } @common_inputs;
        my $uniq_key = substr(md5_hex($key . $string), 0, 16);
        $current->{$uniq_key} = {
            conditions => {
                $which => $key,
                map { $_ => $r->param($_) } grep { $r->param($_) ne '' } @common_inputs
            },
            value => $r->param('otm_value'),
        };
    }
    $quants_config->custom_otm_threshold($json->encode($current));
    $need_to_save = 1;
}

if ($r->param('delete_otm')) {
    my $current = $json->decode($quants_config->custom_otm_threshold);
    unless ($r->param('otm_id')) {
        code_exit_BO('Please specify otm id to delete.');
    }

    delete $current->{$r->param('otm_id')};
    $quants_config->custom_otm_threshold($json->encode($current));
    $need_to_save = 1;
}

BOM::DynamicSettings::dynamic_save() if $need_to_save;

Bar("Limit Definitions");

my $limit_defs          = BOM::Platform::Config::quants->{risk_profile};
my $current_definitions = BOM::Platform::RiskProfile::get_current_profile_definitions();

BOM::Backoffice::Request::template->process(
    'backoffice/profile_definitions.html.tt',
    {
        definitions => $limit_defs,
        current     => $current_definitions,
    }) || die BOM::Backoffice::Request::template->error;

Bar("Existing limits");

my $custom_limits = $json->decode($quants_config->custom_product_profiles);

my @output;
foreach my $id (keys %$custom_limits) {
    my $data = $custom_limits->{$id};
    my $output_ref;
    my %copy = %$data;
    $output_ref->{id}         = $id;
    $output_ref->{name}       = delete $copy{name};
    $output_ref->{updated_by} = delete $copy{updated_by};
    $output_ref->{updated_on} = delete $copy{updated_on};
    my $profile = delete $copy{risk_profile};
    $output_ref->{payout_limit}     = $limit_profile->{$profile}{payout}{USD};
    $output_ref->{turnover_limit}   = $limit_profile->{$profile}{turnover}{USD};
    $output_ref->{condition_string} = join "\n", map { $_ . "[$copy{$_}] " } keys %copy;
    push @output, $output_ref;
}

BOM::Backoffice::Request::template->process(
    'backoffice/existing_limit.html.tt',
    {
        output => \@output,
    }) || die BOM::Backoffice::Request::template->error;

Bar("Custom Client Limits");

my $custom_client_limits = $json->decode($quants_config->custom_client_profiles);

my @client_output;
foreach my $client_loginid (keys %$custom_client_limits) {
    my %data       = %{$custom_client_limits->{$client_loginid}};
    my $reason     = $data{reason};
    my $limits     = $data{custom_limits};
    my $updated_by = $data{updated_by};
    my $updated_on = $data{updated_on};
    my @output;
    foreach my $id (keys %$limits) {
        my $output_ref;
        my %copy = %{$limits->{$id}};
        delete $copy{name};
        my $profile = delete $copy{risk_profile};
        $output_ref->{id}               = $id;
        $output_ref->{payout_limit}     = $limit_profile->{$profile}{payout}{USD};
        $output_ref->{turnover_limit}   = $limit_profile->{$profile}{turnover}{USD};
        $output_ref->{condition_string} = join "\n", map { $_ . "[$copy{$_}] " } keys %copy;
        push @output, $output_ref;
    }
    push @client_output,
        +{
        client_loginid => $client_loginid,
        reason         => $reason,
        updated_by     => $updated_by,
        updated_on     => $updated_on,
        @output ? (output => \@output) : (),
        }
        if @output;
}

BOM::Backoffice::Request::template->process(
    'backoffice/custom_client_limit.html.tt',
    {
        output => \@client_output,
    }) || die BOM::Backoffice::Request::template->error;

Bar("Update Limit");

BOM::Backoffice::Request::template->process(
    'backoffice/update_limit.html.tt',
    {
        url => request()->url_for('backoffice/quant/product_management.cgi'),
    }) || die BOM::Backoffice::Request::template->error;

Bar("Custom OTM Threshold");

BOM::Backoffice::Request::template->process(
    'backoffice/update_otm_threshold.html.tt',
    {
        url             => request()->url_for('backoffice/quant/product_management.cgi'),
        existing_custom => $json->decode($quants_config->custom_otm_threshold),
    }) || die BOM::Backoffice::Request::template->error;

code_exit_BO();
