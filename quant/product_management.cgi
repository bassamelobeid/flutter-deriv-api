#!/usr/bin/perl

package main;

use strict;
use warnings;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use JSON qw(from_json to_json);
use f_brokerincludeall;

use BOM::Platform::Runtime;
use BOM::Platform::Static::Config;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Product::Offerings qw(get_offerings_with_filter);
use List::Util qw(first);
use Digest::MD5 qw(md5_hex);
use Date::Utility;

use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Product Management');
BOM::Backoffice::Auth0::can_access(['Quants']);

my $staff          = BOM::Backoffice::Auth0::from_cookie()->{nickname};
my $r              = request();
my $limit_profile  = BOM::System::Config::quants->{risk_profile};
my %known_profiles = map { $_ => 1 } keys %$limit_profile;

if ($r->param('update_limit')) {
    my @known_keys = qw(contract_category market submarket underlying_symbol start_type expiry_type);
    my %known_values = map { $_ => [get_offerings_with_filter($_)] } @known_keys;
    my %ref;

    foreach my $key (@known_keys) {
        if (my $value = $r->param($key)) {
            if (first { $value eq $_ } @{$known_values{$key}}) {
                $ref{$key} = $value;
            } else {
                print "Unrecognized value[" . $r->param($key) . "] for $key. Nothing is updated!!";
                code_exit_BO();
            }
        }
    }

    my $uniq_key = substr(md5_hex(join('_', sort { $a cmp $b } values %ref)), 0, 16);

    # if we just want to add client into watchlist, custom conditions is not needed
    my $has_custom_conditions = keys %ref;
    if (my $custom_name = $r->param('custom_name')) {
        $ref{name} = $custom_name;
    } elsif ($has_custom_conditions) {
        print "Name is required";
        code_exit_BO();
    }

    my $p = $r->param('risk_profile');
    if ($p and $known_profiles{$p}) {
        $ref{risk_profile} = $p;
    } elsif ($has_custom_conditions) {
        print "Unrecognize risk profile.";
        code_exit_BO();
    }

    if (my $id = $r->param('client_loginid')) {
        my $current = from_json(BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles);
        my $comment = $r->param('comment');
        $current->{$id}->{custom_limits}->{$uniq_key} = \%ref    if $has_custom_conditions;
        $current->{$id}->{reason}                     = $comment if $comment;
        $current->{$id}->{updated_by}                 = $staff;
        $current->{$id}->{updated_on}                 = Date::Utility->new->date;
        BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles(to_json($current));
    } else {
        my $current = from_json(BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles);
        $ref{updated_by}      = $staff;
        $ref{updated_on}      = Date::Utility->new->date;
        $current->{$uniq_key} = \%ref;
        BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(to_json($current));
    }

    BOM::Platform::Runtime->instance->app_config->save_dynamic;
}

if ($r->param('delete_limit')) {
    my $id = $r->param('id');
    if (not $id) {
        print "ID is required. Nothing is deleted.";
        code_exit_BO();
    }

    if (my $client_loginid = $r->param('client_loginid')) {
        my $current = from_json(BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles);
        delete $current->{$client_loginid}->{custom_limits}->{$id};
        BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles(to_json($current));
    } else {
        my $current = from_json(BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles);
        delete $current->{$id};
        BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(to_json($current));
    }

    BOM::Platform::Runtime->instance->app_config->save_dynamic;
}

if ($r->param('delete_client')) {
    my $client_loginid = $r->param('client_loginid');
    my $current        = from_json(BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles);
    delete $current->{$client_loginid};
    BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles(to_json($current));
    BOM::Platform::Runtime->instance->app_config->save_dynamic;
}

Bar("Existing limits");

my $config        = BOM::Platform::Runtime->instance->app_config->quants;
my $custom_limits = from_json($config->custom_product_profiles);

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

BOM::Platform::Context::template->process(
    'backoffice/existing_limit.html.tt',
    {
        output => \@output,
    }) || die BOM::Platform::Context::template->error;

Bar("Custom Client Limits");

my $custom_client_limits = from_json($config->custom_client_profiles);

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

BOM::Platform::Context::template->process(
    'backoffice/custom_client_limit.html.tt',
    {
        output => \@client_output,
    }) || die BOM::Platform::Context::template->error;

Bar("Update Limit");

BOM::Platform::Context::template->process(
    'backoffice/update_limit.html.tt',
    {
        url => request()->url_for('backoffice/quant/product_management.cgi'),
    }) || die BOM::Platform::Context::template->error;

code_exit_BO();
