use strict;
use warnings;
use Test::More tests => 10;
use Test::Exception;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use Test::MockTime qw(set_fixed_time restore_time);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my $t = build_mojo_test();

my %jp_client_details = (
    new_account_japan                           => 1,
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


my ($vr_client, $user, $token, $jp_loginid, $jp_client);
subtest 'create VRTJ & JP client' => sub {
    # new VR client
    ($vr_client, $user) = create_vr_account({
            email           => 'test@binary.com',
            client_password => 'abc123',
            residence       => 'jp',
        });

    # authorize
    $token = BOM::Platform::SessionCookie->new(
        loginid => $vr_client->loginid,
        email   => $vr_client->email,
    )->token;
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    # new JP client
    $t = $t->send_ok({json => \%jp_client_details})->message_ok;
    my $res = decode_json($t->message->[1]);
    $jp_loginid = $res->{new_account_japan}->{client_id};
};

subtest 'no test taken yet' => sub {
    $t = $t->send_ok({json => {get_settings => 1}})->message_ok;
    my $res = decode_json($t->message->[1]);
    is $res->{get_settings}->{jp_account_status}->{status}, 'jp_knowledge_test_pending', 'jp_knowledge_test_pending';
};

subtest 'First Test taken: fail test' => sub {
    $t = $t->send_ok({json => {
            jp_knowledge_test   => 1,
            score               => 10,
            status              => 'fail',
        }})->message_ok;
    my $res = decode_json($t->message->[1]);

    my $epoch = $res->{jp_knowledge_test}->{test_taken_epoch};
    like $epoch, qr/^\d+$/, "test taken time is epoch: $epoch";

    subtest 'get_settings' => sub {
        $t = $t->send_ok({json => { get_settings => 1 }})->message_ok;
        my $res = decode_json($t->message->[1])->{get_settings}->{jp_account_status};

        is $res->{status}, 'jp_knowledge_test_fail';
        like $res->{last_test_epoch}, qr/^\d+$/, 'Last test taken time is epoch';
        like $res->{next_test_epoch}, qr/^\d+$/, 'Next allowable test time is epoch';
    };

    subtest 'Test result exists in financial assessment' => sub {
        $jp_client = BOM::Platform::Client->new({loginid => $jp_loginid});
        my $financial_data = from_json($jp_client->financial_assessment->data);

        my $tests = $financial_data->{jp_knowledge_test};
        is @{$tests}, 1, '1 test record';

        my $test_1 = $tests->[0];
        is $test_1->{score}, 10, 'correct score';
        is $test_1->{status}, 'fail', 'correct status';
        like $test_1->{epoch}, qr/^\d+$/, 'correct epoch format';
    };
};

subtest 'No test allow within same day' => sub {
    $t = $t->send_ok({json => {
            jp_knowledge_test   => 1,
            score               => 18,
            status              => 'pass',
        }})->message_ok;
    my $res = decode_json($t->message->[1]);

    is $res->{error}->{code}, 'AttemptExceeded', 'Number of attempt exceeded for knowledge test';
};

subtest 'Test is allowed after 1 day' => sub {
    lives_ok {
        my $financial_data = from_json($jp_client->financial_assessment->data);

        my $results = $financial_data->{jp_knowledge_test};
        my $last_test = pop @$results;

        $last_test->{epoch} = $last_test->{epoch} - 86400;
        push @{$results}, $last_test;

        $financial_data->{jp_knowledge_test} = $results;
        $jp_client->financial_assessment({data => encode_json($financial_data)});

        $jp_client->save();
    } 'fake last test date';

    subtest 'Pass test' => sub {
        $t = $t->send_ok({json => {
                jp_knowledge_test   => 1,
                score               => 18,
                status              => 'pass',
            }})->message_ok;
        my $res = decode_json($t->message->[1]);

        my $epoch = $res->{jp_knowledge_test}->{test_taken_epoch};
        like $epoch, qr/^\d+$/, "test taken time is epoch: $epoch";
    };

    subtest 'get_settings' => sub {
        $t = $t->send_ok({json => { get_settings => 1 }})->message_ok;
        my $res = decode_json($t->message->[1]);

        is $res->{get_settings}->{jp_account_status}->{status}, 'jp_activation_pending';
    };

    subtest '2 Tests result in financial assessment' => sub {
        $jp_client = BOM::Platform::Client->new({loginid => $jp_loginid});
        my $financial_data = from_json($jp_client->financial_assessment->data);

        my $tests = $financial_data->{jp_knowledge_test};
        is @{$tests}, 2, '2 test records';

        my $test_2 = $tests->[1];
        is $test_2->{score}, 18, 'Test 2: correct score';
        is $test_2->{status}, 'pass', 'Test 2: correct status';
        like $test_2->{epoch}, qr/^\d+$/, 'Test 2: correct epoch format';
    };
};

subtest 'No test allowed after passing' => sub {
    $t = $t->send_ok({json => {
            jp_knowledge_test   => 1,
            score               => 18,
            status              => 'pass',
        }})->message_ok;
    my $res = decode_json($t->message->[1]);

    is $res->{error}->{code}, 'NotEligible', 'NotEligible';
};

subtest 'Test not allowed for non Japanese Client' => sub {
    subtest 'create VRTC & CR client' => sub {
        # new VRTC client
        ($vr_client, $user) = create_vr_account({
                email           => 'test+au@binary.com',
                client_password => 'abc123',
                residence       => 'au',
            });
        # authorize
        $token = BOM::Platform::SessionCookie->new(
                loginid => $vr_client->loginid,
                email   => $vr_client->email,
            )->token;
        $t = $t->send_ok({json => {authorize => $token}})->message_ok;

        # new CR client
        my %cr_client_details = (
            new_account_real => 1,
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

        $t = $t->send_ok({json => \%cr_client_details})->message_ok;
        my $res = decode_json($t->message->[1]);
        my $cr_loginid = $res->{new_account_real}->{client_id};

        like($cr_loginid, qr/^CR\d+$/, "got CR client $cr_loginid");
    };

    subtest 'get_settings has NO jp_account_status' => sub {
        $t = $t->send_ok({json => {get_settings => 1}})->message_ok;
        my $res = decode_json($t->message->[1]);

        is $res->{get_settings}->{jp_account_status}, undef, 'NO jp_account_status';
    };

    subtest 'Test not allowed for VRTC Client' => sub {
        $t = $t->send_ok({json => {
                jp_knowledge_test   => 1,
                score               => 18,
                status              => 'pass',
            }})->message_ok;
        my $res = decode_json($t->message->[1]);

        is $res->{error}->{code}, 'PermissionDenied', 'PermissionDenied';
    };
};

subtest 'No test allowed for VRTJ, unless JP exists' => sub {
    lives_ok {
        ($vr_client, $user) = create_vr_account({
                email           => 'test+jp01@binary.com',
                client_password => 'abc123',
                residence       => 'jp',
            });

        # authorize
        $token = BOM::Platform::SessionCookie->new(
            loginid => $vr_client->loginid,
            email   => $vr_client->email,
        )->token;

        $t = $t->send_ok({json => {authorize => $token}})->message_ok;
    } 'new VRTJ client & authorize';

    subtest 'get_settings has NO jp_account_status' => sub {
        $t = $t->send_ok({json => {get_settings => 1}})->message_ok;
        my $res = decode_json($t->message->[1]);

        is $res->{get_settings}->{jp_account_status}, undef, 'NO jp_account_status';
    };

    subtest 'Test not allowed, unless upgraded to JP client' => sub {
        $t = $t->send_ok({json => {
                jp_knowledge_test   => 1,
                score               => 18,
                status              => 'pass',
            }})->message_ok;
        my $res = decode_json($t->message->[1]);

        is $res->{error}->{code}, 'PermissionDenied', 'PermissionDenied';
    };
};


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

$t->finish_ok;
