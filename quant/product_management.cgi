#!/usr/bin/perl

package main;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use JSON qw(from_json);
use f_brokerincludeall;

use BOM::Platform::Runtime;
use BOM::Platform::Static::Config;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('Product Management');
BOM::Backoffice::Auth0::can_access(['Quants']);

Bar("Existing limits");

my $limit_profile = BOM::Platform::Static::Config::quants->{risk_profile};
my $config = BOM::Platform::Runtime->instance->app_config->quants;
my $custom_limits = from_json($config->custom_product_profiles);

my @output;
foreach my $data (@$custom_limits) {
    my $output_ref;
    my %copy = %$data;
    $output_ref->{name} = delete $copy{name};
    my $profile = delete $copy{risk_profile};
    $output_ref->{payout_limit} = $limit_profile->{$profile}{payout}{USD};
    $output_ref->{turnover_limit} = $limit_profile->{$profile}{turnover}{USD};
    $output_ref->{condition_string} = join "\n", map {"$_: $copy{$_}"} keys %copy;
    push @output, $output_ref;
}

BOM::Platform::Context::template->process(
    'backoffice/existing_limit.html.tt',
    {
        output             => \@output,
    }) || die BOM::Platform::Context::template->error;

Bar("Custom Client Limits");

my $custom_client_limits = from_json($config->custom_client_profiles);

my @client_output;
foreach my $client_loginid (keys %$custom_client_limits) {
    my %data = %{$custom_client_limits->{$client_loginid}};
    my $reason = $data{reason};
    my $limits = $data{custom_limits};
    my @output;
    foreach my $limit_ref (@$limits) {
        my $output_ref;
        my %copy = %$limit_ref;
        my $profile = delete $copy{risk_profile};
        $output_ref->{payout_limit} = $limit_profile->{$profile}{payout}{USD};
        $output_ref->{turnover_limit} = $limit_profile->{$profile}{turnover}{USD};
        $output_ref->{condition_string} = join "\n", map {"$_: $copy{$_}"} keys %copy;
        push @output, $output_ref;
    }
    push @client_output, +{
        client_loginid => $client_loginid,
        reason => $reason,
        output => \@output,
    };
}

BOM::Platform::Context::template->process(
    'backoffice/custom_client_limit.html.tt',
    {
        output             => \@client_output,
    }) || die BOM::Platform::Context::template->error;

code_exit_BO();
