#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use Date::Utility;
use Digest::MD5 qw(md5_hex);
use HTML::Entities;
use JSON::MaybeXS;
use LandingCompany::Registry;
use List::Util qw(first all);
use Text::Trim qw(trim);
use f_brokerincludeall;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::DynamicSettings;
use BOM::Config;
use BOM::Platform::RiskProfile;
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::QuantsAuditLog;
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use BOM::Config::Runtime;

BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new(
    pretty    => 1,
    canonical => 1
);

PrintContentType();
BrokerPresentation('Product Management');

my $args_content;
my $staff         = BOM::Backoffice::Auth0::get_staffname();
my $r             = request();
my $limit_profile = BOM::Config::quants()->{risk_profile};
my $app_config    = BOM::Config::Runtime->instance->app_config;

# for write, we pass in the writer here
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
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
my $disabled_write           = not BOM::Backoffice::Auth0::has_quants_write_access();

if ($r->param('update_limit')) {

    code_exit_BO("permission denied: no write access") if $disabled_write;
    my $landing_company           = $r->param('landing_company');
    my $contract_category         = $r->param('contract_category');
    my $non_binary_contract_limit = $r->param('non_binary_contract_limit');

    my @known_keys    = qw(contract_category market submarket underlying_symbol start_type expiry_type barrier_category landing_company risk_profile);
    my $offerings_obj = LandingCompany::Registry->get_default_company->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
    my %known_values  = map { $_ => [$offerings_obj->values_for_key($_)] } @known_keys;

    # there's no separate in offerings for intraday and ultra_short duration. So adding it here
    push @{$known_values{expiry_type}}, 'ultra_short';
    # landing company is not part of offerings object.
    $known_values{landing_company} = [map { $_->short } LandingCompany::Registry->get_all()];
    $known_values{risk_profile}    = [keys %known_profiles];
    my %ref;

    foreach my $key (@known_keys) {
        if (my $value = $r->param($key)) {
            $value = trim($value);
            if ($allowed_multiple{$key}) {
                for my $elem (split ',', $value) {
                    unless (first { $elem eq $_ } @{$known_values{$key}}) {
                        code_exit_BO("Unrecognized value[" . encode_entities($r->param($key)) . "] for $key. Nothing is updated!!");
                    }
                    $ref{$key} = $value;
                }
            } elsif (
                first {
                    $value eq $_
                }
                @{$known_values{$key}})
            {
                $ref{$key} = $value;
            } else {
                code_exit_BO("Unrecognized value[" . encode_entities($r->param($key)) . "] for $key. Nothing is updated!!");
            }
        }
    }

    my $start_time = $r->param('start_time');
    if ($start_time) {
        code_exit_BO("invalid start_time, $start_time") unless _is_valid_time($start_time);
        $ref{start_time} = $start_time;
    }
    my $end_time = $r->param('end_time');
    if ($end_time) {
        code_exit_BO("invalid end_time, $end_time") unless _is_valid_time($end_time);
        code_exit_BO("end_time is in the past, $end_time")
            unless Date::Utility->new($end_time)->is_after(Date::Utility->new);
        $ref{end_time} = $end_time;
    }
    if ($start_time && $end_time) {
        if (Date::Utility->new($end_time)->is_before(Date::Utility->new($start_time))) {
            code_exit_BO("invalid range end_time < start_time ($end_time < $start_time)");
        }
    }

    my $uniq_key = substr(md5_hex(sort { $a cmp $b } values %ref), 0, 16);

    # if we just want to add client into watchlist, custom conditions is not needed
    my $has_custom_conditions = keys(%ref);
    if (my $custom_name = $r->param('custom_name')) {
        $ref{name} = $custom_name;
        if ($contract_category eq 'lookback') {
            if (0 + $non_binary_contract_limit eq $non_binary_contract_limit) {
                $ref{non_binary_contract_limit} = $non_binary_contract_limit;
            } else {
                code_exit_BO('Non binary contract limit must be number.');
            }
        }
    } elsif ($has_custom_conditions || !$r->param('client_loginid')) {
        code_exit_BO('Name is required.');
    }

    my $profile    = $r->param('risk_profile');
    my $commission = $r->param('commission');
    $profile    = trim $profile    if defined $profile;
    $commission = trim $commission if defined $commission;

    if ($profile and $commission) {
        code_exit_BO('You can only set risk_profile or commission in one entry');
    }

    if ($profile and $known_profiles{$profile}) {
        $ref{risk_profile} = $profile;
    } elsif (defined $commission) {
        if ((0 + $commission ne $commission) || $commission < 0 || $commission > 1) {
            code_exit_BO('Commission must be in [0,1] range.');
        }
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
        send_trading_ops_email(
            "Product management: client limit updated ($id##$uniq_key):",
            {
                %ref,
                updated_by => $staff,
                updated_on => Date::Utility->new->date
            });
    } else {
        $ref{updated_by}                       = $staff;
        $ref{updated_on}                       = Date::Utility->new->date;
        $current_product_profiles->{$uniq_key} = \%ref;
        send_notification_email(\%ref, 'Disable') if ($profile and $profile eq 'no_business');
        send_trading_ops_email("Product management: limit updated ($uniq_key):", \%ref);
        $current_product_profiles = _filter_past_limits($current_product_profiles);
        $app_config->set({'quants.custom_product_profiles' => $json->encode($current_product_profiles)});

        $args_content = join(q{, }, map { qq{$_ => $ref{$_}} } keys %ref);
        BOM::Backoffice::QuantsAuditLog::log($staff, "updatecustomlimitviaPMS", $args_content);
    }
}

if ($r->param('delete_limit')) {
    code_exit_BO("permission denied: no write access") if $disabled_write;
    my $id = $r->param('id');
    code_exit_BO('ID is required. Nothing is deleted.') if not $id;

    if (my $client_loginid = $r->param('client_loginid')) {
        send_trading_ops_email("Product management: client limit deleted ($client_loginid##$id):",
            $current_client_profiles->{$client_loginid}->{custom_limits}->{$id});
        delete $current_client_profiles->{$client_loginid}->{custom_limits}->{$id};
        $app_config->set({'quants.custom_client_profiles' => $json->encode($current_client_profiles)});

        $args_content =
            join(q{, }, map { qq{$_ =>  $current_client_profiles->{$client_loginid}->{$_}} } keys %{$current_client_profiles->{$client_loginid}});
        BOM::Backoffice::QuantsAuditLog::log($staff, "deleteclientlimitviaPMS clientid: $client_loginid", $args_content);

    } else {
        send_notification_email($current_product_profiles->{$id}, 'Enable')
            if exists $current_product_profiles->{$id}->{risk_profile} and $current_product_profiles->{$id}->{risk_profile} eq 'no_business';
        send_trading_ops_email("Product management: limit deleted ($id):", $current_product_profiles->{$id});

        $args_content = join(q{, }, map { qq{$_ =>  $current_product_profiles->{$id}->{$_}} } keys %{$current_product_profiles->{$id}});
        BOM::Backoffice::QuantsAuditLog::log($staff, "deletecustomlimitviaPMS id:$id", $args_content);
        delete $current_product_profiles->{$id};
        $app_config->set({'quants.custom_product_profiles' => $json->encode($current_product_profiles)});

    }
}

if ($r->param('delete_client')) {
    code_exit_BO("permission denied: no write access") if $disabled_write;
    my $client_loginid = $r->param('client_loginid');

    my @limit_ids = keys %{$current_client_profiles->{$client_loginid}->{custom_limits}};
    send_trading_ops_email(
        "Product management: $client_loginid deleted from custom client limits:",
        {
            "limit ids" => join "\n",
            @limit_ids
        }) if scalar @limit_ids;
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
    my $profile = $copy{risk_profile};

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
        url      => request()->url_for('backoffice/quant/product_management.cgi'),
        disabled => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

sub send_notification_email {
    my $limit = shift;
    my $for   = shift;

    my $subject           = "$for Asset/Product Notification. ";
    my $contract_category = $limit->{contract_category} // "Not specified";
    my $market            = $limit->{market}            // "Not specified";
    my $submarket         = $limit->{submarket}         // "Not specified";
    my $underlying        = $limit->{underlying_symbol} // "Not specified";
    my $expiry_type       = $limit->{expiry_type}       // "Not specified";
    my $landing_company   = $limit->{landing_company}   // "Not specified";
    my $barrier_category  = $limit->{barrier_category}  // "Not specified";
    my $start_type        = $limit->{start_type}        // "Not specified";

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

    my $brand = request()->brand;
    my $email_list = join ', ', map { $brand->emails($_) } qw(quants compliance cs marketing_x);

    send_email({
            from    => $brand->emails('system'),
            to      => $email_list,
            subject => $subject,
            message => \@message,

    });
    return;

}

sub _is_valid_time {
    my $time = shift;
    try {
        my $tim_obj = Date::Utility->new($time);
        return 1;
    } catch {
        return 0;
    }
    return 0;
}

sub _filter_past_limits {
    my $limits = shift;
    my $now    = Date::Utility->new;

    my $filtered = {};
    for my $key (keys %$limits) {
        my $limit = $limits->{$key};
        unless ($limit->{end_time} && $now->is_after(Date::Utility->new($limit->{end_time}))) {
            $filtered->{$key} = $limit;
        }
    }
    return $filtered;
}

code_exit_BO();
