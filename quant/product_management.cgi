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

Bar("Product Management");

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
    'backoffice/product_management.html.tt',
    {
        output             => \@output,
    }) || die BOM::Platform::Context::template->error;
code_exit_BO();
