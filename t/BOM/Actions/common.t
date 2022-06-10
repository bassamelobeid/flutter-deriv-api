use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Fatal;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Email;

use BOM::Event::Actions::Common;
use BOM::User;

my $client_mock = Test::MockModule->new('BOM::User::Client');
my $mocked_poa_status;
$client_mock->mock(
    'get_poa_status',
    sub {
        return $mocked_poa_status;
    });

my $p2p_mock  = Test::MockModule->new('BOM::Event::Actions::P2P');
my $p2p_trace = {};
$p2p_mock->mock(
    'p2p_advertiser_approval_changed',
    sub {
        $p2p_trace->{p2p_advertiser_approval_changed} = 1;
    });

my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
my $mocked_poi_name_mismatch;
my $mocked_is_experian_validated;
my $upsert_calls = {};
$status_mock->mock(
    'poi_name_mismatch',
    sub {
        return $mocked_poi_name_mismatch;
    });
$status_mock->mock(
    'is_experian_validated',
    sub {
        return $mocked_is_experian_validated;
    });
$status_mock->mock(
    'upsert',
    sub {
        $upsert_calls->{$_[1]} = 1;
        return $status_mock->original('upsert')->(@_);
    });

my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $emissions    = {};
$emitter_mock->mock(
    'emit',
    sub {
        $emissions = {($_[0] => 1), $emissions->%*,};
        return undef;
    });

my $countries_mock        = Test::MockModule->new('Brands::Countries');
my $mocked_countries_list = {};
$countries_mock->mock(
    'countries_list',
    sub {
        return $mocked_countries_list;
    });

my $landing_company_mock = Test::MockModule->new('LandingCompany');
my $mocked_allowed_landing_companies_for_age_verification_sync;
$landing_company_mock->mock(
    'allowed_landing_companies_for_age_verification_sync',
    sub {
        return $mocked_allowed_landing_companies_for_age_verification_sync;
    });

subtest 'set_age_verification' => sub {
    my $tests = [{
            title    => 'Stopped out early when POI name mismatch',
            email    => 'test1+mismatch@binary.com',
            provider => 'onfido',
            scenario => {
                df_deposit_requires_poi => 1,
                poa_status              => 'none',
                poi_name_mismatch       => 1,
            },
            side_effects => {
                df_deposit_requires_poi         => 1,
                age_verification                => 0,
                poa_email                       => 0,
                p2p_advertiser_approval_changed => 0,
            }
        },
        {
            title    => 'Age verified - experian validated',
            email    => 'test1+experian@binary.com',
            provider => 'experian',
            scenario => {
                poa_status            => 'none',
                poi_name_mismatch     => 0,
                is_experian_validated => 1,
            },
            side_effects => {
                age_verification                => 1,
                poa_email                       => 0,
                upsert_called                   => 1,
                p2p_advertiser_approval_changed => 1,
            }
        },
        {
            title    => 'Age verified - not experian validated',
            email    => 'test1+dummy@binary.com',
            provider => 'dummy',
            scenario => {
                poa_status            => 'none',
                poi_name_mismatch     => 0,
                is_experian_validated => 0,
            },
            side_effects => {
                age_verification                => 1,
                poa_email                       => 0,
                p2p_advertiser_approval_changed => 1,
            }
        },
        {
            title    => 'Age verified - for synthetic',
            email    => 'test1+vrage@binary.com',
            provider => 'dummy',
            scenario => {
                poa_status                         => 'none',
                poi_name_mismatch                  => 0,
                is_experian_validated              => 0,
                require_age_verified_for_synthetic => 1,
            },
            side_effects => {
                age_verification                => 1,
                poa_email                       => 0,
                p2p_advertiser_approval_changed => 1,
                vr_age_verified                 => 1,
            }
        },
        {
            title    => 'Age verified - was df deposit locked',
            email    => 'test1+df+locked@binary.com',
            provider => 'dummy',
            scenario => {
                df_deposit_requires_poi            => 1,
                poa_status                         => 'none',
                poi_name_mismatch                  => 0,
                is_experian_validated              => 0,
                require_age_verified_for_synthetic => 1,
            },
            side_effects => {
                df_deposit_requires_poi         => 0,
                age_verification                => 1,
                poa_email                       => 0,
                p2p_advertiser_approval_changed => 1,
                vr_age_verified                 => 1,
            }
        },
        {
            title    => 'Age verified - landing company sync',
            email    => 'test1+lcsync@binary.com',
            provider => 'dummy',
            scenario => {
                poa_status            => 'none',
                poi_name_mismatch     => 0,
                is_experian_validated => 0,
                allowed_lc_sync       => [qw/malta/]
            },
            side_effects => {
                age_verification                => 1,
                poa_email                       => 0,
                p2p_advertiser_approval_changed => 1,
                mlt_age_verified                => 1,
            }
        },
        {
            title    => 'Age verified - was df deposit locked + landing company sync',
            email    => 'test1+df+locked+lcsync@binary.com',
            provider => 'dummy',
            scenario => {
                df_deposit_requires_poi            => 1,
                poa_status                         => 'none',
                poi_name_mismatch                  => 0,
                is_experian_validated              => 0,
                require_age_verified_for_synthetic => 1,
                allowed_lc_sync                    => [qw/malta/]
            },
            side_effects => {
                df_deposit_requires_poi         => 0,
                age_verification                => 1,
                poa_email                       => 0,
                p2p_advertiser_approval_changed => 1,
                vr_age_verified                 => 1,
                mlt_age_verified                => 1,
            }
        },
        {
            title    => 'Do not send POA email if there is no POA to check',
            email    => 'test1+onfido@binary.com',
            provider => 'onfido',
            scenario => {
                poa_status        => 'none',
                poi_name_mismatch => 0,
            },
            side_effects => {
                poa_email                       => 0,
                age_verification                => 1,
                p2p_advertiser_approval_changed => 1,
            }
        },
        {
            title    => 'Do not send POA email if the POA has been rejected',
            email    => 'test2+onfido@binary.com',
            provider => 'onfido',
            scenario => {
                poa_status        => 'rejected',
                poi_name_mismatch => 0,
            },
            side_effects => {
                poa_email                       => 0,
                age_verification                => 1,
                p2p_advertiser_approval_changed => 1,
            }
        },
        {
            title    => 'Do not send POA email if the POA has been verified',
            email    => 'test3+smile_identity@binary.com',
            provider => 'smile_identity',
            scenario => {
                poa_status        => 'verified',
                poi_name_mismatch => 0,
            },
            side_effects => {
                poa_email                       => 0,
                age_verification                => 1,
                p2p_advertiser_approval_changed => 1,
            }
        },
        {
            title    => 'Send POA email when the POA is pending',
            email    => 'test4+zaig@binary.com',
            provider => 'zaig',
            scenario => {
                poa_status        => 'pending',
                poi_name_mismatch => 0,
            },
            side_effects => {
                poa_email                       => 1,
                age_verification                => 1,
                p2p_advertiser_approval_changed => 1,
            }
        },
    ];

    for my $test ($tests->@*) {
        my ($title, $email, $provider, $scenario, $side_effects) = @{$test}{qw/title email provider scenario side_effects/};

        $mocked_poa_status                                          = $scenario->{poa_status};
        $mocked_poi_name_mismatch                                   = $scenario->{poi_name_mismatch};
        $mocked_is_experian_validated                               = $scenario->{is_experian_validated};
        $mocked_allowed_landing_companies_for_age_verification_sync = $scenario->{allowed_lc_sync} // [];

        subtest $title => sub {
            my $user = BOM::User->create(
                email          => $email,
                password       => 'hey you',
                email_verified => 1,
            );

            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email       => $email,
            });

            my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MLT',
                email       => $email,
            });

            my $vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
            });

            # since we would like to test change in this status, better to don't mock it
            if ($scenario->{df_deposit_requires_poi}) {
                $client->status->set('df_deposit_requires_poi', 'test', 'test');
                $client_mlt->status->set('df_deposit_requires_poi', 'test', 'test');
                $vr->status->set('df_deposit_requires_poi', 'test', 'test');
            }

            $user->add_client($vr);
            $user->add_client($client);
            $user->add_client($client_mlt);

            $mocked_countries_list = {$client->residence => {require_age_verified_for_synthetic => $scenario->{require_age_verified_for_synthetic}}};

            $upsert_calls = {};
            $emissions    = {};
            $p2p_trace    = {};
            mailbox_clear();
            BOM::Event::Actions::Common::set_age_verification($client, $provider);

            my @mailbox = BOM::Test::Email::email_list();
            my $emails  = +{map { $_->{subject} => 1 } @mailbox};
            $client->status->_build_all;

            if ($side_effects->{age_verification}) {
                ok $client->status->age_verification, 'Age verified';
                ok exists $emails->{'Your identity is verified'}, 'Verified notitication sent';
            } else {
                ok !$client->status->age_verification, 'Age status not verified';
                ok !exists $emails->{'Your identity is verified'}, 'Verified notitication not sent';
            }

            if ($side_effects->{df_deposit_requires_poi}) {
                ok $client->status->df_deposit_requires_poi,     'DF deposit lock is there';
                ok $client_mlt->status->df_deposit_requires_poi, 'DF deposit lock is there';
                ok $vr->status->df_deposit_requires_poi,         'DF deposit lock is there';
            } else {
                ok !$client->status->df_deposit_requires_poi,     'DF deposit lock is gone';
                ok !$client_mlt->status->df_deposit_requires_poi, 'DF deposit lock is gone'
                    if scalar @$mocked_allowed_landing_companies_for_age_verification_sync;
                ok !$vr->status->df_deposit_requires_poi, 'DF deposit lock is gone';
            }

            if ($side_effects->{poa_email}) {
                ok exists $emails->{'Pending POA document for: ' . $client->loginid}, 'Pending POA email sent';
            } else {
                ok !exists $emails->{'Pending POA document for: ' . $client->loginid}, 'Pending POA email was not sent';
            }

            if ($side_effects->{upsert_called}) {
                ok exists $upsert_calls->{age_verification}, 'Upsert called';
            } else {
                ok !exists $upsert_calls->{age_verification}, 'Upsert was not called';
            }

            if ($side_effects->{p2p_advertiser_approval_changed}) {
                ok exists $p2p_trace->{p2p_advertiser_approval_changed}, 'Called p2p_advertiser_approval_changed';
            } else {
                ok !exists $p2p_trace->{p2p_advertiser_approval_changed}, 'Not called p2p_advertiser_approval_changed';
            }

            if ($side_effects->{vr_age_verified}) {
                ok $vr->status->age_verification, 'VRTC Age verified';
            } else {
                ok !$vr->status->age_verification, 'VRTC not age verified';
            }

            if ($side_effects->{mlt_age_verified}) {
                ok $client_mlt->status->age_verification, 'MLT Age verified';
            } else {
                ok !$client_mlt->status->age_verification, 'MLT not age verified';
            }
        };
    }
};

subtest 'trigger_cio_broadcast' => sub {
    is BOM::Event::Actions::Common::trigger_cio_broadcast({}), 0, 'no campaign_id';
    is BOM::Event::Actions::Common::trigger_cio_broadcast({campaign_id => 1}), 0, 'no user ids';

    my $cio_mock = Test::MockModule->new('BOM::Event::Actions::CustomerIO');
    $cio_mock->redefine(trigger_broadcast_by_ids => sub { @_ });
    my @res = BOM::Event::Actions::Common::trigger_cio_broadcast({
        campaign_id => 1,
        ids         => [1, 2],
        xyz         => 'abc'
    });
    cmp_deeply(\@res, [ignore(), 1, [1, 2], {xyz => 'abc'}], 'trigger_broadcast_by_ids called correctly');
};

$client_mock->unmock_all;
$status_mock->unmock_all;
$countries_mock->unmock_all;
$landing_company_mock->unmock_all;
$p2p_mock->unmock_all;

done_testing();
