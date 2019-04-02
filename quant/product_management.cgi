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
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::QuantsAuditLog;
BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new(
    pretty    => 1,
    canonical => 1
);

PrintContentType();
BrokerPresentation('Product Management');

my $args_content;
my $staff            = BOM::Backoffice::Auth0::get_staffname();
my $r                = request();
my $limit_profile    = BOM::Config::quants()->{risk_profile};
my $app_config       = BOM::Config::Runtime->instance->app_config;
my %known_profiles   = map { $_ => 1 } keys %$limit_profile;
my %allowed_multiple = (
    market            => 1,
    submarket         => 1,
    underlying_symbol => 1,
    landing_company   => 1,
);

my $current_config           = $app_config->get(['quants.custom_client_profiles', 'quants.custom_product_profiles']);
my $current_client_profiles  = $json->decode($current_config->{'quants.custom_client_profiles'});
my $current_product_profiles = $json->decode($current_config->{'quants.custom_product_profiles'});

if ($r->param('update_limit')) {

    my $landing_company           = $r->param('landing_company');
    my $contract_category         = $r->param('contract_category');
    my $non_binary_contract_limit = $r->param('non_binary_contract_limit');

    my @known_keys    = qw(contract_category market submarket underlying_symbol start_type expiry_type barrier_category landing_company);
    my $offerings_obj = LandingCompany::Registry::get('costarica')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
    my %known_values  = map { $_ => [$offerings_obj->values_for_key($_)] } @known_keys;

    # there's no separate in offerings for intraday and ultra_short duration. So adding it here
    push @{$known_values{expiry_type}}, 'ultra_short';
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
        my $comment = $r->param('comment');
        $current_client_profiles->{$id}->{custom_limits}->{$uniq_key} = \%ref    if $has_custom_conditions;
        $current_client_profiles->{$id}->{reason}                     = $comment if $comment;
        $current_client_profiles->{$id}->{updated_by}                 = $staff;
        $current_client_profiles->{$id}->{updated_on}                 = Date::Utility->new->date;
        $app_config->set({'quants.custom_client_profiles' => $json->encode($current_client_profiles)});

        $args_content = join(q{, }, map { qq{$_ =>  $current_client_profiles->{$id}->{$_}} } keys %{$current_client_profiles->{$id}});
        BOM::Backoffice::QuantsAuditLog::log($staff, "updateclientlimitviaPMS clientid:$id", $args_content);

    } else {
        $ref{updated_by}                       = $staff;
        $ref{updated_on}                       = Date::Utility->new->date;
        $current_product_profiles->{$uniq_key} = \%ref;
        send_notification_email(\%ref, 'Disable') if ($profile and $profile eq 'no_business');
        $app_config->set({'quants.custom_product_profiles' => $json->encode($current_product_profiles)});

        $args_content = join(q{, }, map { qq{$_ => $ref{$_}} } keys %ref);
        BOM::Backoffice::QuantsAuditLog::log($staff, "updatecustomlimitviaPMS", $args_content);
    }

}

if ($r->param('delete_limit')) {
    my $id = $r->param('id');
    code_exit_BO('ID is required. Nothing is deleted.') if not $id;

    if (my $client_loginid = $r->param('client_loginid')) {
        delete $current_client_profiles->{$client_loginid}->{custom_limits}->{$id};
        $app_config->set({'quants.custom_client_profiles' => $json->encode($current_client_profiles)});

        $args_content =
            join(q{, }, map { qq{$_ =>  $current_client_profiles->{$client_loginid}->{$_}} } keys %{$current_client_profiles->{$client_loginid}});
        BOM::Backoffice::QuantsAuditLog::log($staff, "deleteclientlimitviaPMS clientid: $client_loginid", $args_content);

    } else {
        send_notification_email($current_product_profiles->{$id}, 'Enable')
            if exists $current_product_profiles->{$id}->{risk_profile} and $current_product_profiles->{$id}->{risk_profile} eq 'no_business';

        $args_content = join(q{, }, map { qq{$_ =>  $current_product_profiles->{$id}->{$_}} } keys %{$current_product_profiles->{$id}});
        BOM::Backoffice::QuantsAuditLog::log($staff, "deletecustomlimitviaPMS id:$id", $args_content);
        delete $current_product_profiles->{$id};
        $app_config->set({'quants.custom_product_profiles' => $json->encode($current_product_profiles)});

    }
}

if ($r->param('delete_client')) {
    my $client_loginid = $r->param('client_loginid');
    delete $current_client_profiles->{$client_loginid};
    $app_config->set({'quants.custom_client_profiles' => $json->encode($current_client_profiles)});

    $args_content =
        join(q{, }, map { qq{$_ =>  $current_client_profiles->{$client_loginid}->{$_}} } keys %{$current_client_profiles->{$client_loginid}});
    BOM::Backoffice::QuantsAuditLog::log($staff, "deleteclientlimitviaPMS: $client_loginid", $args_content);

}

Bar("Limit Definitions");

my $limit_defs          = BOM::Config::quants()->{risk_profile};
my $current_definitions = BOM::Platform::RiskProfile::get_current_profile_definitions();

BOM::Backoffice::Request::template()->process(
    'backoffice/profile_definitions.html.tt',
    {
        definitions => $limit_defs,
        current     => $current_definitions,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Existing limits");

my $custom_limits = $json->decode($app_config->get('quants.custom_product_profiles'));

my @output;
foreach my $id (sort { $custom_limits->{$b}->{updated_on} cmp $custom_limits->{$a}->{updated_on} } keys %$custom_limits) {
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

BOM::Backoffice::Request::template()->process(
    'backoffice/existing_limit.html.tt',
    {
        output => \@output,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Update Limit");

BOM::Backoffice::Request::template()->process(
    'backoffice/update_limit.html.tt',
    {
        url => request()->url_for('backoffice/quant/product_management.cgi'),
    }) || die BOM::Backoffice::Request::template()->error;

sub send_notification_email {
    my $limit = shift;
    my $for   = shift;

    my $subject           = "$for Asset/Product Notification. ";
    my $contract_category = $limit->{contract_category} // "Not specified";
    my $market            = $limit->{market} // "Not specified";
    my $submarket         = $limit->{submarket} // "Not specified";
    my $underlying        = $limit->{underlying_symbol} // "Not specified";
    my $expiry_type       = $limit->{expiry_type} // "Not specified";
    my $landing_company   = $limit->{landing_company} // "Not specified";
    my $barrier_category  = $limit->{barrier_category} // "Not specified";
    my $start_type        = $limit->{start_type} // "Not specified";

    my @message = "$for the following offering: ";
    push @message,
        (
        "Contract Category: $contract_category",
        "Expiry Type: $expiry_type",
        "Market: $market",
        "Submarket: $submarket",
        "Underlying: $underlying",
        "Barrier category: $barrier_category",
        "Start type: $start_type",
        "Landing_company: $landing_company",
        "Reason: " . $limit->{name},
        );
    push @message, ("By " . $limit->{updated_by} . " on " . $limit->{updated_on});

    my $email_list = 'x-quants@binary.com, compliance@binary.com, x-cs@binary.com,x-marketing@binary.com';

    send_email({
            from    => 'system@binary.com',
            to      => $email_list,
            subject => $subject,
            message => \@message,

    });
    return;

}

code_exit_BO();
