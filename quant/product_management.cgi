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
use Try::Tiny;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::DynamicSettings;
use BOM::Config;
use BOM::Platform::RiskProfile;
use BOM::Platform::RiskProfile;
use BOM::Config::Runtime;

BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new;

PrintContentType();
BrokerPresentation('Product Management');

my $staff            = BOM::Backoffice::Auth0::from_cookie()->{nickname};
my $r                = request();
my $limit_profile    = BOM::Config::quants->{risk_profile};
my $quants_config    = BOM::Config::Runtime->instance->app_config->quants;
my %known_profiles   = map { $_ => 1 } keys %$limit_profile;
my %allowed_multiple = (
    market            => 1,
    submarket         => 1,
    underlying_symbol => 1,
    landing_company   => 1,
);

my $need_to_save = 0;

if ($r->param('update_limit')) {

    my $landing_company           = $r->param('landing_company');
    my $contract_category         = $r->param('contract_category');
    my $non_binary_contract_limit = $r->param('non_binary_contract_limit');

    my @known_keys    = qw(contract_category market submarket underlying_symbol start_type expiry_type barrier_category landing_company);
    my $offerings_obj = LandingCompany::Registry::get('costarica')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
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
        $ref{non_binary_contract_limit} = $non_binary_contract_limit if $contract_category eq 'lookback';
    } elsif ($has_custom_conditions) {
        code_exit_BO('Name is required.');
    }

    my $profile    = $r->param('risk_profile');
    my $commission = $r->param('commission');

    if ($profile and $commission) {
        code_exit_BO('You can only set risk_profile or commission in one entry');
    }

    if ($profile and $known_profiles{$profile}) {
        $ref{risk_profile} = $profile;
    } elsif ($commission) {
        $ref{commission} = $commission;
    } elsif ($has_custom_conditions and $contract_category ne 'lookback') {
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

BOM::DynamicSettings::dynamic_save() if $need_to_save;

Bar("Limit Definitions");

my $limit_defs          = BOM::Config::quants->{risk_profile};
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

    if ($profile) {
        $output_ref->{payout_limit}   = $limit_profile->{$profile}{payout}{USD};
        $output_ref->{turnover_limit} = $limit_profile->{$profile}{turnover}{USD};
    }
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

Bar("Japan KLFB");

if ($r->param('update_klfb_limit')) {
    my $config = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        recorded_date    => Date::Utility->new,
    );
    try {
        $config->save_config(
            'klfb',
            {
                limit      => $r->param('klfb_limit'),
                date       => $r->param('klfb_date'),
                updated_by => $staff
            });
        print "saved successful";
    }
    catch {
        print $_;
    };

}

BOM::Backoffice::Request::template->process(
    'backoffice/japan_klfb.html.tt',
    {
        url           => request()->url_for('backoffice/quant/product_management.cgi'),
        existing_klfb => BOM::Config::QuantsConfig->new(chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader())->get_config('klfb')->[0],
    }) || die BOM::Backoffice::Request::template->error;

code_exit_BO();
