use strict;
use warnings;
use Test::More tests => 8;
use Test::Exception;
use JSON;

use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Account::Virtual;
use BOM::RPC::v3::NewAccount;
use BOM::RPC::v3::NewAccount::Japan;
use BOM::RPC::v3::Accounts;

## do not send email
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my %jp_client_details = (
    gender                                      => 'f',
    first_name                                  => 'first\'name',
    last_name                                   => 'last-name',
    date_of_birth                               => '1990-12-30',
    occupation                                  => 'Director',
    residence                                   => 'jp',
    address_line_1                              => 'Hiroo Miyata Bldg 3F',
    address_line_2                              => '9-16, Hiroo 1-chome',
    address_city                                => 'Shibuya-ku',
    address_state                               => 'Tokyo',
    address_postcode                            => '150-0012',
    phone                                       => '+81 3 4333 6908',
    secret_question                             => 'Favourite dish',
    secret_answer                               => 'nasi lemak,teh tarik',
    annual_income                               => '50-100 million JPY',
    financial_asset                             => 'Over 100 million JPY',
    daily_loss_limit                            => 100000,
    trading_experience_equities                 => 'Over 5 years',
    trading_experience_commodities              => 'Over 5 years',
    trading_experience_foreign_currency_deposit => '3-5 years',
    trading_experience_margin_fx                => '6 months to 1 year',
    trading_experience_investment_trust         => '3-5 years',
    trading_experience_public_bond              => 'Over 5 years',
    trading_experience_option_trading           => 'Less than 6 months',
    trading_purpose                             => 'Hedging',
    hedge_asset                                 => 'Foreign currency deposit',
    hedge_asset_amount                          => 1000000,
    agree_use_electronic_doc                    => 1,
    agree_warnings_and_policies                 => 1,
    confirm_understand_own_judgment             => 1,
    confirm_understand_trading_mechanism        => 1,
    confirm_understand_judgment_time            => 1,
    confirm_understand_total_loss               => 1,
    confirm_understand_sellback_loss            => 1,
    confirm_understand_shortsell_loss           => 1,
    confirm_understand_company_profit           => 1,
    confirm_understand_expert_knowledge         => 1,
    declare_not_fatca                           => 1,
);

my ($vr_client, $user, $token, $jp_loginid, $jp_client, $res);

my $dt_mocked = Test::MockModule->new('DateTime');
$dt_mocked->mock('day_of_week', sub { return 1 });

subtest 'create VRTJ & JP client' => sub {
    # new VR client
    ($vr_client, $user) = create_vr_account({
        email           => 'test@binary.com',
        client_password => 'abc123',
        residence       => 'jp',
    });

    $token = BOM::Platform::SessionCookie->new(
        loginid => $vr_client->loginid,
        email   => $vr_client->email,
    )->token;

    # new JP client
    $res = BOM::RPC::v3::NewAccount::new_account_japan({
        token => $token,
        args  => \%jp_client_details
    });
    $jp_loginid = $res->{client_id};
    like $jp_loginid, qr/^JP\d+$/, "JP client created";
};

subtest 'no test taken yet' => sub {
    $res = BOM::RPC::v3::Accounts::get_settings({token => $token})->{jp_account_status};
    is $res->{status}, 'jp_knowledge_test_pending', 'jp_knowledge_test_pending';
    like $res->{next_test_epoch}, qr/^\d+$/, 'Test available time is epoch';
};

my $test_epoch;
subtest 'First Test taken: fail test' => sub {
    $res = BOM::RPC::v3::NewAccount::Japan::jp_knowledge_test({
            token => $token,
            args  => {
                score  => 10,
                status => 'fail'
            }});

    $test_epoch = $res->{test_taken_epoch};
    like $test_epoch, qr/^\d+$/, "test taken time is epoch";

    subtest 'get_settings' => sub {
        $res = BOM::RPC::v3::Accounts::get_settings({token => $token})->{jp_account_status};

        is $res->{status},          'jp_knowledge_test_fail';
        is $res->{last_test_epoch}, $test_epoch, 'Correct last test taken time';
        is $res->{next_test_epoch}, $test_epoch + 86400, 'Next allowable test is tomorrow';
    };

    subtest 'Test result exists in financial assessment' => sub {
        $jp_client = BOM::Platform::Client->new({loginid => $jp_loginid});
        my $financial_data = from_json($jp_client->financial_assessment->data);

        my $tests = $financial_data->{jp_knowledge_test};
        is @{$tests}, 1, '1 test record';

        my $test_1 = $tests->[0];
        is $test_1->{score},  10,     'correct score';
        is $test_1->{status}, 'fail', 'correct status';
        is $test_1->{epoch}, $test_epoch, 'correct test taken epoch';
    };
};

subtest 'No test allow within same day' => sub {
    $res = BOM::RPC::v3::NewAccount::Japan::jp_knowledge_test({
            token => $token,
            args  => {
                score  => 18,
                status => 'pass'
            }});
    is($res->{error}->{code}, 'TestUnavailableNow', 'Test not available for now');
};

subtest 'Test is allowed after 1 day' => sub {
    lives_ok {
        my $financial_data = from_json($jp_client->financial_assessment->data);

        my $results   = $financial_data->{jp_knowledge_test};
        my $last_test = pop @$results;

        $last_test->{epoch} = $last_test->{epoch} - 86400;
        push @{$results}, $last_test;

        $financial_data->{jp_knowledge_test} = $results;
        $jp_client->financial_assessment({data => encode_json($financial_data)});

        $jp_client->save();
    }
    'fake last test date';

    subtest 'Pass test' => sub {
        $res = BOM::RPC::v3::NewAccount::Japan::jp_knowledge_test({
                token => $token,
                args  => {
                    score  => 18,
                    status => 'pass'
                }});

        $test_epoch = $res->{test_taken_epoch};
        like $test_epoch, qr/^\d+$/, "Test taken time is epoch";
    };

    subtest 'get_settings' => sub {
        $res = BOM::RPC::v3::Accounts::get_settings({token => $token});
        is $res->{jp_account_status}->{status}, 'jp_activation_pending';
    };

    subtest '2 Tests result in financial assessment' => sub {
        $jp_client = BOM::Platform::Client->new({loginid => $jp_loginid});
        my $financial_data = from_json($jp_client->financial_assessment->data);

        my $tests = $financial_data->{jp_knowledge_test};
        is @{$tests}, 2, '2 test records';

        my $test_2 = $tests->[1];
        is $test_2->{score},  18,     'Test 2: correct score';
        is $test_2->{status}, 'pass', 'Test 2: correct status';
        is $test_2->{epoch}, $test_epoch, 'Test 2: correct epoch';
    };
};

subtest 'No test allowed after passing' => sub {
    $res = BOM::RPC::v3::NewAccount::Japan::jp_knowledge_test({
            token => $token,
            args  => {
                score  => 18,
                status => 'pass'
            }});
    is $res->{error}->{code}, 'NotEligible', 'Already pass knowledge test, not eligible now';
};

subtest 'Test not allowed for non Japanese Client' => sub {
    subtest 'create VRTC & CR client' => sub {
        ($vr_client, $user) = create_vr_account({
            email           => 'test+au@binary.com',
            client_password => 'abc123',
            residence       => 'au',
        });

        $token = BOM::Platform::SessionCookie->new(
            loginid => $vr_client->loginid,
            email   => $vr_client->email,
        )->token;

        # new CR client
        my %cr_client_details = (
            salutation       => 'Ms',
            last_name        => 'last-name',
            first_name       => 'first\'name',
            date_of_birth    => '1990-12-30',
            residence        => 'au',
            address_line_1   => 'Jalan Usahawan',
            address_line_2   => 'Enterpreneur Center',
            address_city     => 'Cyberjaya',
            address_state    => 'Selangor',
            address_postcode => '47120',
            phone            => '+603 34567890',
            secret_question  => 'Favourite dish',
            secret_answer    => 'nasi lemak,teh tarik',
        );

        $res = BOM::RPC::v3::NewAccount::new_account_real({
            token => $token,
            args  => \%cr_client_details
        });
        my $cr_loginid = $res->{client_id};
        like($cr_loginid, qr/^CR\d+$/, "got CR client $cr_loginid");
    };

    subtest 'get_settings has NO jp_account_status' => sub {
        $res = BOM::RPC::v3::Accounts::get_settings({token => $token});
        is $res->{jp_account_status}, undef, 'NO jp_account_status';
    };

    subtest 'Test not allowed for VRTC Client' => sub {
        $res = BOM::RPC::v3::NewAccount::Japan::jp_knowledge_test({
                token => $token,
                args  => {
                    score  => 18,
                    status => 'pass'
                }});
        is $res->{error}->{code}, 'PermissionDenied', 'PermissionDenied for VRTC';
    };
};

subtest 'No test allowed for VRTJ, unless JP exists' => sub {
    lives_ok {
        ($vr_client, $user) = create_vr_account({
            email           => 'test+jp01@binary.com',
            client_password => 'abc123',
            residence       => 'jp',
        });

        $token = BOM::Platform::SessionCookie->new(
            loginid => $vr_client->loginid,
            email   => $vr_client->email,
        )->token;
    }
    'new VRTJ client & token';

    subtest 'get_settings has NO jp_account_status' => sub {
        $res = BOM::RPC::v3::Accounts::get_settings({token => $token});
        is $res->{jp_account_status}, undef, 'NO jp_account_status';
    };

    subtest 'Test not allowed, unless upgraded to JP client' => sub {
        $res = BOM::RPC::v3::NewAccount::Japan::jp_knowledge_test({
                token => $token,
                args  => {
                    score  => 18,
                    status => 'pass'
                }});
        is $res->{error}->{code}, 'PermissionDenied', 'PermissionDenied for VRTJ without JP';
    };
};

$client_mocked->unmock_all;
$email_mocked->unmock_all;
$dt_mocked->unmock_all;

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
            },
            email_verified => 1
        });

    return ($acc->{client}, $acc->{user});
}

