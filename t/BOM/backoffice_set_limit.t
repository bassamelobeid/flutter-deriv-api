use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Exception;
use Date::Utility;

use Data::Chronicle::Mock;
use Digest::MD5 qw(md5_hex);
use JSON::MaybeXS;

use BOM::Config;
use BOM::Config::Runtime;
use BOM::Backoffice::Script::SetLimitForQuietPeriod;

subtest 'unique_key_generator' => sub {
    my $test_key          = 'set extreme_risk_forex_intraday_mean_reversion_trade';
    my $manual_unique_key = substr(md5_hex('new' . $test_key), 0, 16);

    my $generated_unique_key = BOM::Backoffice::Script::SetLimitForQuietPeriod::unique_key_generator($test_key);
    is_deeply($manual_unique_key, $generated_unique_key, "Generated unique code matches");

};

subtest 'calculate_time_duration_for_limit' => sub {
    my $now         = Date::Utility->new(1694407430);    #   '2023-09-11 04:45:16';
    my $limit_cause = 'asian_hour';

    my $expected_asian_hour_start_time = '2023-09-11 00:00:00';
    my $expected_asian_hour_end_time   = '2023-09-11 07:00:00';

    my ($asian_hour_start_time, $asian_hour_end_time) =
        BOM::Backoffice::Script::SetLimitForQuietPeriod::calculate_time_duration_for_limit($now, $limit_cause);
    is_deeply($expected_asian_hour_start_time, $asian_hour_start_time->datetime_yyyymmdd_hhmmss, "Calculated start day matches");
    is_deeply($expected_asian_hour_end_time,   $asian_hour_end_time->datetime_yyyymmdd_hhmmss,   "Calculated end day matches");

    $limit_cause = 'mean_reversion';

    my $expected_mean_reversion_start_time = '2023-09-11 22:00:00';
    my $expected_mean_reversion_end_time   = '2023-09-12 00:00:00';

    my ($mean_reversion_start_time, $mean_reversion_end_time) =
        BOM::Backoffice::Script::SetLimitForQuietPeriod::calculate_time_duration_for_limit($now, $limit_cause);
    is_deeply($expected_mean_reversion_start_time, $mean_reversion_start_time->datetime_yyyymmdd_hhmmss, "Calculated start day matches");
    is_deeply($expected_mean_reversion_end_time,   $mean_reversion_end_time->datetime_yyyymmdd_hhmmss,   "Calculated end day matches");

};

subtest 'set_new_limit' => sub {

    my $module = Test::MockModule->new('BOM::Backoffice::Script::SetLimitForQuietPeriod');
    $module->redefine(
        'quants_config_handler',
        sub {
            my ($chronicle_r, $chronicle_w) = Data::Chronicle::Mock::get_mocked_chronicle();
            my $quants_config = BOM::Config::Runtime->instance->app_config;
            $quants_config->chronicle_writer($chronicle_w);

            return $quants_config;
        });

    my $current_product_profiles = {
        'dc9ac6cd7786a3b4' => {
            'updated_by'        => 'c.c',
            'name'              => '10%_comm_ultrashort_fx_callput_Aug',
            'start_time'        => '2023-08-08 02:00:00',
            'market'            => 'forex',
            'contract_category' => 'callput',
            'updated_on'        => '2023-08-01',
            'expiry_type'       => 'ultra_short',
            'end_time'          => '2023-08-08 06:00:00',
            'commission'        => '0.1'
        },
        'ae4ca29fa5bac4eb' => {
            'end_time'     => '2023-08-26 00:00:00',
            'updated_on'   => '2023-08-25 00:00:19',
            'expiry_type'  => 'intraday',
            'start_time'   => '2023-08-25 22:00:00',
            'risk_profile' => 'extreme_risk',
            'market'       => 'forex',
            'updated_by'   => 'cron job',
            'name'         => 'set extreme_risk_forex_intraday_mean_reversion_trade'
        },
        'af2f78247934cca2' => {
            'updated_on'        => '2022-06-21',
            'name'              => 'extreme_risk_touchnotouch',
            'updated_by'        => 'kl',
            'risk_profile'      => 'extreme_risk',
            'contract_category' => 'touchnotouch',
            'market'            => 'indices'
        },
        '17e8129a17c08dfb' => {
            'start_time'        => '2023-08-31 02:00:00',
            'contract_category' => 'callputequal',
            'market'            => 'forex',
            'updated_by'        => 'c.c',
            'name'              => '10%_comm_ultrashort_fx_callpute_Aug',
            'commission'        => '0.1',
            'end_time'          => '2023-08-31 06:00:00',
            'updated_on'        => '2023-08-01',
            'expiry_type'       => 'ultra_short'
        },
        '29d55a5673639cb5' => {
            'name'              => '10%_comm_ultrashort_fx_callput_Aug',
            'updated_by'        => 'c.c',
            'start_time'        => '2023-08-31 02:00:00',
            'market'            => 'forex',
            'contract_category' => 'callput',
            'updated_on'        => '2023-08-01',
            'expiry_type'       => 'ultra_short',
            'commission'        => '0.1',
            'end_time'          => '2023-08-31 06:00:00'
        },
        '4e2fc76ad18096bb' => {
            'updated_by'        => 'ys',
            'name'              => 'extreme_risk_range',
            'updated_on'        => '2022-02-10',
            'market'            => 'indices',
            'risk_profile'      => 'extreme_risk',
            'contract_category' => 'staysinout'
        },
        'eb77d897e98f5160' => {
            'start_time'        => '2023-08-21 02:00:00',
            'contract_category' => 'callputequal',
            'market'            => 'forex',
            'updated_by'        => 'c.c',
            'name'              => '10%_comm_ultrashort_fx_callpute_Aug',
            'commission'        => '0.1',
            'end_time'          => '2023-08-21 06:00:00',
            'updated_on'        => '2023-08-01',
            'expiry_type'       => 'ultra_short'
        },
        'a18cd0cc5bda9026' => {
            'commission'        => '0.1',
            'end_time'          => '2023-08-17 06:00:00',
            'expiry_type'       => 'ultra_short',
            'updated_on'        => '2023-08-01',
            'contract_category' => 'callputequal',
            'market'            => 'forex',
            'start_time'        => '2023-08-17 02:00:00',
            'name'              => '10%_comm_ultrashort_fx_callpute_Aug',
            'updated_by'        => 'c.c'
        },
        'b18411230ced4c66' => {
            'updated_on'   => '2022-11-07 00:00:03',
            'updated_by'   => 'cron job',
            'name'         => 'set extreme_risk_fx_tick_trade',
            'expiry_type'  => 'tick',
            'risk_profile' => 'extreme_risk',
            'market'       => 'forex,basket_index'
        }

    };

    my $to_remove = 'set extreme_risk_forex_intraday_mean_reversion_trade';
    my %new_limit = (
        risk_profile => 'extreme_risk',
        expiry_type  => 'intraday',
        name         => 'set extreme_risk_forex_intraday_mean_reversion_trade',
        updated_by   => 'cron job',
        start_time   => '2023-08-26 22:00:00',
        end_time     => '2023-08-27 00:00:00',
        updated_on   => '2023-08-26 00:00:20',
        market       => 'forex',
    );

    my %initial_product_profiles = %$current_product_profiles;
    my $uniq_key                 = substr(md5_hex('new' . $to_remove), 0, 16);
    BOM::Backoffice::Script::SetLimitForQuietPeriod::set_new_limit($uniq_key, $current_product_profiles, $to_remove, \%new_limit);

    is_deeply($current_product_profiles->{$uniq_key}, \%new_limit, "New limit added correctly");
    is(scalar keys %$current_product_profiles, scalar keys %initial_product_profiles, "Number of profiles matches after removal and addition");
};

done_testing;
