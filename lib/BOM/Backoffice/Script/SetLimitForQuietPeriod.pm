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

    my $quants_config = BOM::Config::Runtime->instance->app_config;
    $quants_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
    my $current                  = $quants_config->get('quants.custom_product_profiles');
    my $current_product_profiles = $json->decode($current);

    #Adding ultra_short to the list to protect us from Ukranian clients.
    #As of Jan 17th, we have 104 Ukranian clients hitting our profit
    #using 1 minute contract.

    foreach my $duration (qw(tick ultra_short)) {

        my ($todo, $risk_profile, $to_remove, $between);
        my $now          = Date::Utility->new;
        my $cut_off_hour = $now->is_dst_in_zone('Europe/London') ? '06' : '07';

        if ($now->hour == 00) {
            $todo         = 'set extreme_risk_fx_' . $duration . '_trade';
            $to_remove    = 'set high_risk_fx_' . $duration . '_trade';
            $risk_profile = 'extreme_risk';
            $between      = "00 to " . $cut_off_hour . 'GMT';

        } elsif ($now->hour == $cut_off_hour) {
            $todo         = 'set high_risk_fx_' . $duration . '_trade';
            $to_remove    = 'set extreme_risk_fx_' . $duration . '_trade';
            $risk_profile = 'high_risk';
            $between      = $cut_off_hour . ' to 00GMT';
        } else {
            next;

        }
        my $uniq_key = substr(md5_hex('new' . $todo), 0, 16);

        #removing old limit (tick trade/ ultra short duration)
        my @removing_keys =
            grep { $current_product_profiles->{$_}->{updated_by} eq 'cron job' and $current_product_profiles->{$_}->{name} eq $to_remove }
            keys %$current_product_profiles;
        delete @{$current_product_profiles}{@removing_keys};

        $quants_config->set({'quants.custom_product_profiles' => $json->encode($current_product_profiles)});

        #imposing new limit on forex (tick trade/ ultra short duration)
        my %new_limit = (
            risk_profile => $risk_profile,
            market       => 'forex',
            expiry_type  => $duration,
            name         => $todo,
            updated_by   => 'cron job',
            updated_on   => Date::Utility->new->datetime,
        );

        $current_product_profiles->{$uniq_key} = \%new_limit;
        $quants_config->set({'quants.custom_product_profiles' => $json->encode($current_product_profiles)});
        send_notification_email(\%new_limit, $todo . ' for forex tick trade between ' . $between);

    }

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
    my $profile           = $limit->{risk_profile} // "Not specified";
    my @message           = "$for \n";
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
        "profile: $profile",
        "Reason: " . $limit->{name},
        );
    push @message, ("By " . $limit->{updated_by} . " on " . $limit->{updated_on});
    my $brand      = BOM::Config->brand();
    my $email_list = join ", ", map { $brand->emails($_) } qw(quants compliance cs marketing_x);

    send_email({
            from    => $brand->emails('system'),
            to      => $email_list,
            subject => $subject,
            message => \@message,

    });
    return;

}

1;
