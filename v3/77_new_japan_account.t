#!perl
use strict;
use warnings;
use Test::More;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;

use await;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('Client::Account');
$client_mocked->mock(add_note => sub { return 1 });
# avoid currency conversion for payment notification
my $pnq_mocked = Test::MockModule->new('BOM::Platform::PaymentNotificationQueue');
$pnq_mocked->mock(add => sub { return Future->done });

my $t = build_wsapi_test();

my %client_details = (
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

subtest 'new JP real account' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test@binary.com',
        client_password => 'abc123',
        residence       => 'jp',
    });

    like($vr_client->loginid, qr/^VRTJ\d+$/, "got VRTJ Virtual client " . $vr_client->loginid);

    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);

    $t->await::authorize({authorize => $token});

    subtest 'create JP account' => sub {
        my ($res, $call_params) = call_mocked_client($t, \%client_details);
        is $call_params->{token}, $token;
        is $res->{msg_type},      'new_account_japan';
        ok($res->{new_account_japan});
        test_schema('new_account_japan', $res);

        my $loginid = $res->{new_account_japan}->{client_id};
        like($loginid, qr/^JP\d+$/, "got JP client $loginid");
    };

    subtest 'jp_knowledge_test' => sub {
        my ($res, $call_params) = call_mocked_client(
            $t,
            {
                "jp_knowledge_test" => 1,
                "score"             => 12,
                "status"            => "pass"
            });
        is $call_params->{token}, $token;
        is $res->{msg_type},      'jp_knowledge_test';
        if ($res->{error}) {
            is $res->{error}->{code}, 'TestUnavailableNow', 'TestUnavailableNow';
        } else {
            ok $res->{jp_knowledge_test};
        }
    };

    subtest 'multiple accounts not allowed even though account is disabled' => sub {
        my $res = $t->await::new_account_japan(\%client_details);

        is($res->{error}->{code}, 'PermissionDenied', 'as japan account is disabled so cannot create new one as disabled one is also considered');
    };

    subtest 'no duplicate allowed - Name + DOB + different email' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'test+test@binary.com',
            client_password => 'abc123',
            residence       => 'jp',
        });
        # authorize
        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        my $res = $t->await::new_account_japan(\%client_details);

        is($res->{error}->{code}, 'duplicate name DOB', 'no duplicate account: same name + DOB');
        is($res->{new_account_real}, undef, 'NO account created');
    };
};

subtest 'Japan a/c jp residence only' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+jp2@binary.com',
        client_password => 'abc123',
        residence       => 'jp',
    });
    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    # create JP real acc
    my %details = %client_details;
    $details{residence} = 'gb';
    $details{first_name} .= '-gb';

    subtest 'UK residence' => sub {
        my $res = $t->await::new_account_japan(\%details);
        is($res->{error}->{code},     'InputValidationFailed',              'residence must be "jp"');
        is($res->{error}->{message},  'Input validation failed: residence', 'jp only');
        is($res->{new_account_japan}, undef,                                'NO account created');
    };
};

subtest 'VR Residence check' => sub {
    subtest 'VR a/c nl residence' => sub {
        # create VR acc
        my ($vr_client, $user) = create_vr_account({
            email           => 'test+jp3@binary.com',
            client_password => 'abc123',
            residence       => 'jp',
        });
        $vr_client->residence('nl');
        $vr_client->save();

        # authorize
        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        # create JP real acc
        my %details = %client_details;
        $details{first_name} .= '-VR-nl';

        subtest 'VRTJ nl residence' => sub {
            my $res = $t->await::new_account_japan(\%details);

            is($res->{error}->{code},     'InvalidAccount',                         'NO VR nl residence');
            is($res->{error}->{message},  'Sorry, account opening is unavailable.', 'jp only');
            is($res->{new_account_japan}, undef,                                    'NO account created');
        };
    };

    subtest 'VR a/c NOT VRTJ, au residence' => sub {
        # create VR acc
        my ($vr_client, $user) = create_vr_account({
            email           => 'test+jp4@binary.com',
            client_password => 'abc123',
            residence       => 'au',
        });
        # authorize
        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        # create JP real acc
        my %details = %client_details;
        $details{first_name} .= '-au';

        subtest 'VRTC au residence' => sub {
            my $res = $t->await::new_account_japan(\%details);

            is($res->{error}->{code},     'PermissionDenied',   'VR residence must be "jp"');
            is($res->{error}->{message},  'Permission denied.', 'VR jp only');
            is($res->{new_account_japan}, undef,                'NO account created');
        };
    };
};

subtest 'jp_knowledge_test' => sub {
    my $res = $t->await::jp_knowledge_test({
        jp_knowledge_test => 1,
        score             => 12,
        status            => "pass"
    });
    is $res->{msg_type}, 'jp_knowledge_test';
    is $res->{error}->{code}, 'PermissionDenied';
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
done_testing;
