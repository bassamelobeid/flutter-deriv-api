use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use BOM::Config::P2P;
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new();
BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->business_hours_minutes_interval(15);

subtest 'manage hours' => sub {

    subtest 'create order chat disabled' => sub {
        $config->create_order_chat(0);

        my $client = BOM::Test::Helper::Client::create_client();

        BOM::User->create(
            email    => 'test1@deriv.com',
            password => 'x'
        )->add_client($client);

        $client->account('USD');
        $client->status->set('age_verification', 'x', 'x');

        cmp_deeply(
            exception {
                $client->p2p_advertiser_create(
                    name     => 'name1',
                    schedule => [{
                            start_min => 0,
                            end_min   => 15
                        },
                        {
                            start_min => 30,
                            end_min   => 59
                        }])
            },
            {
                error_code     => 'InvalidScheduleInterval',
                message_params => [59, 15]
            },
            'Invalid interval'
        );

        cmp_deeply(
            exception { $client->p2p_advertiser_create(name => 'name1', schedule => [{start_min => 30, end_min => 30}]) },
            {error_code => 'InvalidScheduleRange'},
            'Invalid range'
        );

        cmp_deeply(
            exception { $client->p2p_advertiser_create(name => 'name1', schedule => [{start_min => 60, end_min => 30}]) },
            {error_code => 'InvalidScheduleRange'},
            'Another invalid range'
        );

        cmp_deeply(
            $client->p2p_advertiser_create(
                name     => 'name1',
                schedule => [{
                        start_min => 900,
                        end_min   => 1200
                    },
                    {
                        start_min => 0,
                        end_min   => 180
                    },
                    {
                        start_min => 30,
                        end_min   => 300
                    }]
            )->{schedule},
            [{
                    start_min => 0,
                    end_min   => 300
                },
                {
                    start_min => 900,
                    end_min   => 1200
                }
            ],
            'Valid schedule returned from create'
        );

        cmp_deeply(
            $client->p2p_advertiser_info->{schedule},
            [{
                    start_min => 0,
                    end_min   => 300
                },
                {
                    start_min => 900,
                    end_min   => 1200
                }
            ],
            'Schedule returned from p2p_advertiser_info'
        );

        $config->business_hours_minutes_interval(0);

        cmp_deeply(
            $client->p2p_advertiser_update(schedule => [{start_min => 0, end_min => 10080}])->{schedule},
            [{start_min => 0, end_min => 10080}],
            'Updated schedule returned from p2p_advertiser_update'
        );

        cmp_deeply([$client->p2p_advertiser_update(schedule => [])->@{qw(schedule is_schedule_available)}], [undef, 1], 'Delete schedule');

        cmp_deeply([$client->p2p_advertiser_info->@{qw(schedule is_schedule_available)}], [undef, 1], 'Deleted returned from p2p_advertiser_info');

        cmp_ok $client->p2p_advertiser_update(schedule => [{start_min => current_min(), end_min => undef}])->{is_schedule_available}, '==', 1,
            'is_schedule_available is 1 from update';
        cmp_ok $client->p2p_advertiser_info->{is_schedule_available}, '==', 1, 'is_schedule_available is 1 in p2p_advertiser_info';

        cmp_ok $client->p2p_advertiser_update(schedule => [{start_min => 10081, end_min => 10082}])->{is_schedule_available}, '==', 0,
            'is_schedule_available is 0 from update';
        cmp_ok $client->p2p_advertiser_info->{is_schedule_available}, '==', 0, 'is_schedule_available is 0 in p2p_advertiser_info';
    };

    subtest 'create order chat enabled' => sub {
        $config->create_order_chat(1);

        my $client = BOM::Test::Helper::Client::create_client();

        BOM::User->create(
            email    => 'test2@deriv.com',
            password => 'x'
        )->add_client($client);

        $client->account('USD');

        cmp_deeply(
            $client->p2p_advertiser_create(
                name     => 'name2',
                schedule => [{start_min => 330, end_min => 345}]
            )->{schedule},
            [{start_min => 330, end_min => 345}],
            'Valid schedule returned from p2p_advertiser_create'
        );
    };
};

subtest 'adverts & orders' => sub {
    my ($advertiser, $ad) = BOM::Test::Helper::P2P::create_advert(order_expiry_period => 900);
    my $client = BOM::Test::Helper::P2P::create_advertiser;

    cmp_ok $ad->{advertiser_details}{is_schedule_available}, '==', 1, 'advertiser is_schedule_available is 1 on new ad';
    cmp_deeply [map { $_->{id} } $client->p2p_advert_list->@*], [$ad->{id}], 'client sees ad';

    $advertiser->p2p_advertiser_update(schedule => [{start_min => undef, end_min => current_min()}]);
    delete $advertiser->{_p2p_advertiser_cached};

    my $info = $advertiser->p2p_advert_info(id => $ad->{id});
    ok !$info->{advertiser_details}{is_schedule_available}, 'advertiser is_schedule_available is false now';
    ok !$info->{is_visible},                                'is_visible is false';
    cmp_deeply $info->{visibility_status}, ['advertiser_schedule'], 'visibility_status is advertiser_schedule';

    cmp_deeply [map { $_->{id} } $client->p2p_advert_list->@*], [], 'client no longer sees ad';

    cmp_deeply(
        exception { $client->p2p_order_create(advert_id => $ad->{id}, amount => 1, rule_engine => $rule_engine) },
        {error_code => 'AdvertiserScheduleAvailability'},
        'cannot create order when advertiser schedule is not available'
    );

    $advertiser->p2p_advertiser_update(schedule => [{start_min => undef, end_min => undef}]);
    $client->p2p_advertiser_update(schedule => [{start_min => undef, end_min => current_min()}]);

    cmp_ok $client->p2p_advert_info(id => $ad->{id})->{is_client_schedule_available}, '==', 0, 'ad is_client_schedule_available is 0';
    cmp_deeply [map { $_->{id} } $client->p2p_advert_list(hide_client_schedule_unavailable => 1)->@*], [],
        'client does not see ad with hide_client_schedule_unavailable';
    cmp_deeply [map { $_->{id} } $client->p2p_advert_list->@*], [$ad->{id}], 'client sees ad without hide_client_schedule_unavailable';

    cmp_deeply(
        exception { $client->p2p_order_create(advert_id => $ad->{id}, amount => 1, rule_engine => $rule_engine) },
        {error_code => 'ClientScheduleAvailability'},
        'cannot create order when client schedule is not available'
    );

    $advertiser->p2p_advertiser_update(schedule => [{start_min => 0, end_min => 10080}]);
    $client->p2p_advertiser_update(schedule => [{start_min => 0, end_min => 10080}]);

    is(exception { $client->p2p_order_create(advert_id => $ad->{id}, amount => 1, rule_engine => $rule_engine) },
        undef, 'can create order when both party schedules are available');
};

sub current_min {
    my $dt = Date::Utility->new;
    return ($dt->day_of_week * 1440) + ($dt->hour * 60) + $dt->minute;
}

done_testing();
