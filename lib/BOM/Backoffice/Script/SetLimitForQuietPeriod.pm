package BOM::Backoffice::Script::SetLimitForQuietPeriod;
use Moose;
with 'App::Base::Script';
use BOM::Config;
use BOM::Platform::RiskProfile;
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);

use Quant::Framework::VolSurface::Utils qw(NY1700_rollover_date_on);
use Date::Utility;
use Digest::MD5 qw(md5_hex);
use JSON::MaybeXS;

sub documentation { return 'This script is to set limit for quiet period'; }

sub script_run {
    my $self                     = shift;
    my $current                  = quants_config_handler()->get('quants.custom_product_profiles');
    my $current_product_profiles = json_handler()->decode($current);

    #Adding ultra_short to the list to protect us from Ukranian clients.
    #As of Jan 17th, we have 104 Ukranian clients hitting our profit
    #using 1 minute contract.

    foreach my $duration (qw(intraday tick ultra_short)) {
        my ($todo, $risk_profile, $to_remove, $between);
        my $now          = Date::Utility->new;
        my $cut_off_hour = $now->is_dst_in_zone('Europe/London') ? '06' : '07';

        foreach my $type (({market => 'forex'}, {submarket => 'forex_basket,commodity_basket'})) {
            my ($value) = values $type->%*;

            if ($duration eq 'intraday') {
                $risk_profile = 'extreme_risk';
                if ($now->hour == 00) {
                    $todo = "set extreme_risk_${value}_${duration}_trade_asian_hour";
                    my $uniq_key = unique_key_generator($todo);
                    my ($new_limit, $between) = build_new_limit($duration, 'asian_hour', $todo, $risk_profile, $now, $type);
                    set_new_limit($uniq_key, $current_product_profiles, $todo, $new_limit);
                    send_notification_email($new_limit, $todo . ' between ' . $between);

                    if ($value eq 'forex') {
                        $todo = "set extreme_risk_${value}_${duration}_mean_reversion_trade";
                        my $uniq_key = unique_key_generator($todo);
                        my ($new_limit, $between) = build_new_limit($duration, 'mean_reversion', $todo, $risk_profile, $now, $type);
                        set_new_limit($uniq_key, $current_product_profiles, $todo, $new_limit);
                        send_notification_email($new_limit, $todo . ' between ' . $between);
                    }
                }

                next;
            }

            if ($now->hour == 00) {
                $todo         = "set extreme_risk_${value}_${duration}_trade";
                $to_remove    = "set high_risk_${value}_${duration}_trade";
                $risk_profile = 'extreme_risk';
                $between      = "00 to " . $cut_off_hour . 'GMT';

            } elsif ($now->hour == $cut_off_hour) {
                $todo         = "set high_risk_${value}_${duration}_trade";
                $to_remove    = "set extreme_risk_${value}_${duration}_trade";
                $risk_profile = 'high_risk';
                $between      = $cut_off_hour . ' to 00GMT';

            } else {

                next;
            }
            my $uniq_key = unique_key_generator($todo);

            #imposing new limit on forex and basket indices (tick trade/ ultra short duration)
            my %new_limit = (
                risk_profile => $risk_profile,
                expiry_type  => $duration,
                name         => $todo,
                updated_by   => 'cron job',
                updated_on   => Date::Utility->new->datetime,
                $type->%*,
            );

            set_new_limit($uniq_key, $current_product_profiles, $to_remove, \%new_limit);
            send_notification_email(\%new_limit, $todo . ' between ' . $between);
        }

    }

    return 1;
}

=head2 json_handler

This sub routine handles json encoding and decoding

=cut

sub json_handler {
    return JSON::MaybeXS->new(
        pretty    => 1,
        canonical => 1
    );
}

=head2 quants_config_handler

This sub routine handles getting and setting of quants configuration

=cut

sub quants_config_handler {
    my $quants_config = BOM::Config::Runtime->instance->app_config;
    $quants_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
    return $quants_config;
}

=head2 unique_key_generator

This sub routine generates unique key using $key

=cut

sub unique_key_generator {
    my $key = shift;
    return substr(md5_hex('new' . $key), 0, 16);
}

=head2 calculate_time_duration_for_limit

This sub routine sets up start time and end time for new limits

=cut

sub calculate_time_duration_for_limit {
    my $now         = shift;
    my $limit_cause = shift;

    my $start_time = $now->truncate_to_day;
    my $end_time   = $start_time->plus_time_interval('7h');

    if ($limit_cause eq 'mean_reversion') {
        my $rollover_date_time = NY1700_rollover_date_on($now->truncate_to_day);
        my $start_time         = $rollover_date_time->plus_time_interval('1h');
        my $end_time           = $rollover_date_time->plus_time_interval('3h');

        return ($start_time, $end_time);

    }

    return ($start_time, $end_time);

}

=head2 build_new_limit

This sub routine processes the params and builds a hash for the new limit

=cut

sub build_new_limit {
    my $duration     = shift;
    my $limit_cause  = shift;
    my $todo         = shift;
    my $risk_profile = shift;
    my $now          = shift;
    my $type         = shift;

    my $between;
    my ($start_time, $end_time) = calculate_time_duration_for_limit($now, $limit_cause);
    $between = $start_time->hour . ' to ' . $end_time->hour . ' GMT';

    my %new_limit = (
        risk_profile => $risk_profile,
        expiry_type  => $duration,
        name         => $todo,
        updated_by   => 'cron job',
        start_time   => $start_time->datetime_yyyymmdd_hhmmss,
        end_time     => $end_time->datetime_yyyymmdd_hhmmss,
        updated_on   => Date::Utility->new->datetime,
        $type->%*,
    );

    return (\%new_limit, $between);
}

=head2 set_new_limit

This sub routine removes existing limits based on given parameters and set up new limits

=cut

sub set_new_limit {
    my $uniq_key                 = shift;
    my $current_product_profiles = shift;
    my $to_remove                = shift;
    my $new_limit                = shift;

    my @removing_keys =
        grep { $current_product_profiles->{$_}->{updated_by} eq 'cron job' and $current_product_profiles->{$_}->{name} eq $to_remove }
        keys %$current_product_profiles;

    delete @{$current_product_profiles}{@removing_keys};

    $current_product_profiles->{$uniq_key} = $new_limit;
    quants_config_handler()->set({'quants.custom_product_profiles' => json_handler()->encode($current_product_profiles)});

}

sub send_notification_email {
    my $limit = shift;
    my $for   = shift;

    my $subject           = "Trading limit setting. ";
    my $contract_category = $limit->{contract_category} // "Not specified";
    my $market            = $limit->{market}            // "Not specified";
    my $submarket         = $limit->{submarket}         // "Not specified";
    my $underlying        = $limit->{underlying_symbol} // "Not specified";
    my $expiry_type       = $limit->{expiry_type}       // "Not specified";
    my $landing_company   = $limit->{landing_company}   // "Not specified";
    my $barrier_category  = $limit->{barrier_category}  // "Not specified";
    my $start_type        = $limit->{start_type}        // "Not specified";
    my $profile           = $limit->{risk_profile}      // "Not specified";
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
    my $email_list = join ", ", map { $brand->emails($_) } qw(quants compliance_regs cs marketing_x);

    send_email({
            from    => $brand->emails('system'),
            to      => $email_list,
            subject => $subject,
            message => \@message,

    });
    return;

}

1;
