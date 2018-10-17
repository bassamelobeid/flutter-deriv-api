package BOM::Backoffice::Script::SetLimitForQuietPeriod;
use Moose;
with 'App::Base::Script';
use BOM::Config;
use BOM::Platform::RiskProfile;
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);
use Date::Utility;
use Digest::MD5 qw(md5_hex);
use JSON::MaybeXS;

sub documentation { return 'This script is to set limit for quiet period'; }

sub script_run {
    my $self = shift;

    my $json = JSON::MaybeXS->new(
        pretty    => 1,
        canonical => 1
    );
    my %new_limit;
    my $quants_config            = BOM::Config::Runtime->instance->app_config;
    my $current                  = $quants_config->get('quants.custom_product_profiles');
    my $current_product_profiles = $json->decode($current);
    my ($todo, $risk_profile, $to_remove);
    my $now = Date::Utility->new;
    my $cut_off_hour = $now->is_dst_in_zone('Europe/London') ? '06' : '07';

    if ($now->hour == 00) {
        $todo         = 'set extreme_risk_fx_tick_trade';
        $to_remove    = 'set moderate_risk_fx_tick_trade';
        $risk_profile = 'extreme_risk';

    } elsif ($now->hour == $cut_off_hour) {
        $todo         = 'set moderate_risk_fx_tick_trade';
        $to_remove    = 'set extreme_risk_fx_tick_trade';
        $risk_profile = 'moderate_risk';
    } else {
        return 1;

    }

    my $uniq_key = substr(md5_hex('new' . $todo), 0, 16);

    #removing old limit on forex tick trade
    map { delete $current_product_profiles->{$_} }
        grep { $current_product_profiles->{$_}->{updated_by} eq 'cron job' and $current_product_profiles->{$_}->{name} eq $to_remove }
        keys %$current_product_profiles;

    $quants_config->set({'quants.custom_product_profiles' => $json->encode($current_product_profiles)});

    #imposing new limit on forex tick trade
    $new_limit{risk_profile} = $risk_profile;
    $new_limit{market}       = 'forex';
    $new_limit{expiry_type}  = 'tick';
    $new_limit{name}         = $todo;
    $new_limit{updated_by}   = 'cron job';
    $new_limit{updated_on}   = Date::Utility->new->datetime;

    $current_product_profiles->{$uniq_key} = \%new_limit;
    $quants_config->set({'quants.custom_product_profiles' => $json->encode($current_product_profiles)});
    send_notification_email(\%new_limit, 'Setting extreme risk for forex tick trade between 0 to 6GMT');

    return 1;
}

sub send_notification_email {
    my $limit = shift;
    my $for   = shift;

    my $subject           = "Trading limit setting. ";
    my $contract_category = $limit->{contract_category} // "Not specified";
    my $market            = $limit->{market} // "Not specified";
    my $submarket         = $limit->{submarket} // "Not specified";
    my $underlying        = $limit->{underlying_symbol} // "Not specified";
    my $expiry_type       = $limit->{expiry_type} // "Not specified";
    my $landing_company   = $limit->{landing_company} // "Not specified";
    my $barrier_category  = $limit->{barrier_category} // "Not specified";
    my $start_type        = $limit->{start_type} // "Not specified";

    my @message = "$for \n";
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

1;
