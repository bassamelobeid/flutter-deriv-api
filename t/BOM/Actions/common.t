use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Fatal;
use Test::Deep;
use Future::AsyncAwait;
use BOM::Event::Services;
use IO::Async::Loop;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Email;
use BOM::Test::Helper::Client qw(invalidate_object_cache);
use BOM::Platform::Context    qw( request );

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
my $upsert_calls = {};
my $is_idv_validated;
$status_mock->mock(
    'poi_name_mismatch',
    sub {
        return $mocked_poi_name_mismatch;
    });
$status_mock->mock(
    'is_idv_validated',
    sub {
        return $is_idv_validated;
    });
$status_mock->mock(
    'upsert',
    sub {
        $upsert_calls->{$_[1]} = 1;
        return $status_mock->original('upsert')->(@_);
    });

my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
my @emissions;
$emitter_mock->mock(
    'emit',
    sub {
        push @emissions, @_;
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

# Redis
my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

sub _redis_events_write {
    return $services->redis_events_write();
}

my $redis = _redis_events_write();

subtest 'set_age_verification' => sub {
    my $tests = [{
            title      => 'Stopped out early when POI name mismatch',
            email      => 'test1+mismatch@binary.com',
            provider   => 'onfido',
            poi_method => 'onfido',
            scenario   => {
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
            title      => 'Age verified - for synthetic',
            email      => 'test1+vrage@binary.com',
            provider   => 'onfido',
            poi_method => 'onfido',
            scenario   => {
                poa_status                         => 'none',
                poi_name_mismatch                  => 0,
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
            title      => 'Age verified - was df deposit locked',
            email      => 'test1+df+locked@binary.com',
            provider   => 'onfido',
            poi_method => 'onfido',
            scenario   => {
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
            title      => 'Age verified - landing company sync',
            email      => 'test1+lcsync@binary.com',
            provider   => 'onfido',
            poi_method => 'onfido',
            scenario   => {
                poa_status        => 'none',
                poi_name_mismatch => 0,
                allowed_lc_sync   => [qw/maltainvest/]
            },
            side_effects => {
                age_verification                => 1,
                poa_email                       => 0,
                p2p_advertiser_approval_changed => 1,
                mf_age_verified                 => 1,
            }
        },
        {
            title      => 'Age verified - was df deposit locked + landing company sync',
            email      => 'test1+df+locked+lcsync@binary.com',
            provider   => 'onfido',
            poi_method => 'onfido',
            scenario   => {
                df_deposit_requires_poi            => 1,
                poa_status                         => 'none',
                poi_name_mismatch                  => 0,
                is_experian_validated              => 0,
                require_age_verified_for_synthetic => 1,
                allowed_lc_sync                    => [qw/maltainvest/]
            },
            side_effects => {
                df_deposit_requires_poi         => 0,
                age_verification                => 1,
                poa_email                       => 0,
                p2p_advertiser_approval_changed => 1,
                vr_age_verified                 => 1,
                mf_age_verified                 => 1,
            }
        },
        {
            title      => 'Do not send POA email if there is no POA to check',
            email      => 'test1+onfido@binary.com',
            provider   => 'onfido',
            poi_method => 'onfido',
            scenario   => {
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
            title      => 'Do not send POA email if the POA has been rejected',
            email      => 'test2+onfido@binary.com',
            provider   => 'onfido',
            poi_method => 'onfido',
            scenario   => {
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
            title      => 'Do not send POA email if the POA has been verified',
            email      => 'test3+smile_identity@binary.com',
            provider   => 'smile_identity',
            poi_method => 'idv',
            scenario   => {
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
            title      => 'Do not send POA email if the POA is pending for CR',
            email      => 'test4+zaig@binary.com',
            provider   => 'zaig',
            poi_method => 'idv',
            scenario   => {
                poa_status        => 'pending',
                poi_name_mismatch => 0,
            },
            side_effects => {
                poa_email                       => 0,
                age_verification                => 1,
                p2p_advertiser_approval_changed => 1,
            }
        },
        {
            title      => 'Should call upsert when IDV verified',
            email      => 'test5+zaig@binary.com',
            provider   => 'zaig',
            poi_method => 'idv',
            scenario   => {
                poa_status        => 'none',
                poi_name_mismatch => 0,
                is_idv_validated  => 1,
            },
            side_effects => {
                age_verification                => 1,
                p2p_advertiser_approval_changed => 1,
            }
        },
    ];

    for my $test ($tests->@*) {
        my ($title, $email, $provider, $scenario, $side_effects, $poi_method) = @{$test}{qw/title email provider scenario side_effects poi_method/};

        $mocked_poa_status                                          = $scenario->{poa_status};
        $mocked_poi_name_mismatch                                   = $scenario->{poi_name_mismatch};
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

            my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MF',
                email       => $email,
            });

            my $vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
            });

            # since we would like to test change in this status, better to don't mock it
            if ($scenario->{df_deposit_requires_poi}) {
                $client->status->set('df_deposit_requires_poi', 'test', 'test');
                $client_mf->status->set('df_deposit_requires_poi', 'test', 'test');
                $vr->status->set('df_deposit_requires_poi', 'test', 'test');
            }

            # setting up age verification
            if (exists $scenario->{age_verification}) {
                $client->status->set('age_verification', 'test', $scenario->{age_verification});
            }
            # setting up idv validation
            if (exists $scenario->{is_idv_validated}) {
                $is_idv_validated = $scenario->{is_idv_validated};
            } else {
                $is_idv_validated = 0;
            }

            $user->add_client($vr);
            $user->add_client($client);
            $user->add_client($client_mf);

            $mocked_countries_list = {$client->residence => {require_age_verified_for_synthetic => $scenario->{require_age_verified_for_synthetic}}};

            $upsert_calls = {};
            @emissions    = [];
            $p2p_trace    = {};
            mailbox_clear();

            undef @emissions;

            my $redis_events_write = _redis_events_write();
            $redis_events_write->connect->get;
            my $res = BOM::Event::Actions::Common::set_age_verification($client, $provider, $redis_events_write, $poi_method)->get;

            my @mailbox = BOM::Test::Email::email_list();
            my $emails  = +{map { $_->{subject} => 1 } @mailbox};
            $client->status->_build_all;

            if ($side_effects->{age_verification}) {
                ok $res;
                ok $client->status->age_verification, 'Age verified';

                if (exists $side_effects->{age_verification_reason}) {
                    is $client->status->reason('age_verification'), $side_effects->{age_verification_reason}, 'Exptected reason for age verification';
                }
                is_deeply \@emissions,
                    [
                    'age_verified',
                    {
                        'properties' => {
                            'website_name'  => 'Deriv.com',
                            'name'          => $client->first_name,
                            'email'         => $client->email,
                            'contact_url'   => 'https://deriv.com/en/contact-us',
                            'poi_url'       => 'https://app.deriv.com/account/proof-of-identity?lang=en',
                            'live_chat_url' => 'https://deriv.com/en/?is_livechat_open=true'
                        },
                        'loginid' => $client->loginid,
                    }
                    ],
                    'Verified notitication sent to CR client';
                undef @emissions;
            } else {
                ok !$res;
                ok !$client->status->age_verification, 'Age status not verified';
                ok !exists $emissions[0],              'Verified notitication not sent to CR client';
            }

            if ($side_effects->{df_deposit_requires_poi}) {
                ok $client->status->df_deposit_requires_poi,    'DF deposit lock is there';
                ok $client_mf->status->df_deposit_requires_poi, 'DF deposit lock is there';
                ok $vr->status->df_deposit_requires_poi,        'DF deposit lock is there';
            } else {
                ok !$client->status->df_deposit_requires_poi, 'DF deposit lock is gone';
                ok !$client_mf->status->df_deposit_requires_poi, 'DF deposit lock is gone'
                    if scalar @$mocked_allowed_landing_companies_for_age_verification_sync;
                ok !$vr->status->df_deposit_requires_poi, 'DF deposit lock is gone';
            }

            if ($side_effects->{poa_email}) {
                ok exists $emails->{'Pending POA document for: ' . $client->loginid}, 'Pending POA email sent';

                BOM::Event::Actions::Common::set_age_verification($client, $provider, $redis_events_write, $poi_method)->get;

                @mailbox = BOM::Test::Email::email_list();

                ok $redis_events_write->get('PENDING::POA::EMAIL::LOCK::' . $client->loginid), 'redis lock set';

                ok !scalar @mailbox, 'No mail sent';

            } else {
                ok !exists $emails->{'Pending POA document for: ' . $client->loginid}, 'Pending POA email was not sent';
            }

            unless ($scenario->{is_idv_validated}) {
                if ($side_effects->{upsert_called}) {
                    ok exists $upsert_calls->{age_verification}, 'Upsert called';
                } else {
                    ok !exists $upsert_calls->{age_verification}, 'Upsert was not called';
                }
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

            if ($side_effects->{mf_age_verified}) {
                ok $client_mf->status->age_verification, 'MF Age verified';
            } else {
                ok !$client_mf->status->age_verification, 'MF not age verified';
            }
        };
    }
};

subtest 'trigger_cio_broadcast' => sub {
    is BOM::Event::Actions::Common::trigger_cio_broadcast({}),                 0, 'no campaign_id';
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

subtest 'underage handling' => sub {
    my $user = BOM::User->create(
        email          => 'underage+handle.me@binary.com',
        password       => 'hey you',
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $user->email,
    });

    my $from = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'underage+prev@binary.com',
    });

    my $emissions    = {};
    my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $emitter_mock->mock(
        'emit',
        sub {
            my ($event, $args) = @_;

            $emissions->{$event} = $args;
        });

    my $siblings    = {};
    my $client_mock = Test::MockModule->new(ref($client));
    $client_mock->mock(
        'real_account_siblings_information',
        sub {
            return $siblings;
        });

    my $user_mock    = Test::MockModule->new(ref($user));
    my $mt5_loginids = [];
    my $dxt_loginids = [];
    $user_mock->mock(
        'get_trading_platform_loginids',
        sub {
            my (undef, %args) = @_;
            return $dxt_loginids->@* if $args{platform} eq 'dxtrade';
            return $mt5_loginids->@* if $args{platform} eq 'mt5';
            return ();
        });

    my $tests = [{
            balance => 1,
            mt5     => [],
            dxtrade => [],
            result  => 'email',
        },
        {
            balance => 0,
            mt5     => ['MTR1001'],
            dxtrade => [],
            result  => 'email',
        },
        {
            balance => 0,
            mt5     => [],
            dxtrade => ['DXR1001'],
            result  => 'email',
        },
        {
            balance => 0,
            mt5     => [],
            dxtrade => ['DXR1001'],
            result  => 'email',
            from    => $from,
        },
        {
            balance => 0,
            mt5     => [],
            dxtrade => [],
            result  => 'track',
            reason  => 'qa - client is underage',
        },
        {
            balance => 0,
            mt5     => [],
            dxtrade => [],
            result  => 'track',
            reason  => 'qa - client is underage - same documents as ' . $from->loginid,
            from    => $from,
        },
    ];

    my $brand = request->brand;
    for my $test ($tests->@*) {
        my ($balance, $mt5, $dxtrade, $result, $reason, $from) = @{$test}{qw/balance mt5 dxtrade result reason from/};

        $siblings->{$client->loginid}->{balance} = $balance;
        $mt5_loginids                            = $mt5;
        $dxt_loginids                            = $dxtrade;

        mailbox_clear();
        $emissions = {};
        $client->status->clear_disabled;
        $client->status->_clear_all;
        $client->status->_build_all;

        BOM::Event::Actions::Common::handle_under_age_client($client, 'qa', $from);
        invalidate_object_cache($client);

        my $email = mailbox_search(subject => qr/Underage client detection/);

        if ($result eq 'email') {
            cmp_deeply $emissions, {}, 'No emissions';

            ok $email, 'Expected email sent';

            ok !$client->status->disabled, 'client is not disabled';

            ok index($email->{body}, $_) > -1, 'contains ' . $_ . ' mention' for $mt5_loginids->@*;
            ok index($email->{body}, $_) > -1, 'contains ' . $_ . ' mention' for $dxtrade->@*;
            ok index($email->{body}, 'The client tried to authenticate underage documents from ' . $from->loginid) > -1 if $from;
            is index($email->{body}, 'The client tried to authenticate underage documents from'), -1 unless $from;
        } else {
            my $params = {
                language => uc($client->user->preferred_language // request->language // 'en'),
            };
            cmp_deeply $emissions,
                {
                underage_account_closed => {
                    loginid    => $client->loginid,
                    properties => {
                        tnc_approval => $brand->tnc_approval_url($params),
                    }}
                },
                'Expected emissions';

            ok $client->status->disabled, 'client has been disabled';

            is $client->status->reason('disabled'), $reason, 'Expected disabled reason';

            ok !$email, 'No email sent';
        }
    }

    $emitter_mock->unmock_all;
    $client_mock->unmock_all;
    $user_mock->unmock_all;
};

subtest '_send_CS_email_POA_pending' => sub {
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    my $mock_client = Test::MockModule->new('BOM::User::Client');

    mailbox_clear();
    BOM::Event::Actions::Common::_send_CS_email_POA_pending($client_mf);

    my $msg = mailbox_search(subject => qr/Pending POA document for/);
    ok !$msg, 'No email sent for not age verified client';

    $client_mf->status->setnx('age_verification', 'test', 'test');

    $mock_client->mock(fully_authenticated => sub { return 1 });

    mailbox_clear();
    BOM::Event::Actions::Common::_send_CS_email_POA_pending($client_mf);

    $msg = mailbox_search(subject => qr/Pending POA document for/);
    ok !$msg, 'No email sent for fully authenticated client';

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client_cr->status->setnx('age_verification', 'test', 'test');

    mailbox_clear();
    BOM::Event::Actions::Common::_send_CS_email_POA_pending($client_cr);

    $msg = mailbox_search(subject => qr/Pending POA document for/);
    ok !$msg, 'No email sent for non MF client';

    $client_mf->status->setnx('age_verification', 'test', 'test');
    $mock_client->mock(fully_authenticated => sub { return 0 });

    mailbox_clear();
    BOM::Event::Actions::Common::_send_CS_email_POA_pending($client_mf);

    $msg = mailbox_search(subject => qr/Pending POA document for/);
    ok $msg, 'Email sent for MF client';

    $client_mf->status->clear_age_verification;
    mailbox_clear();
    $mock_client->unmock_all();
};

done_testing();
