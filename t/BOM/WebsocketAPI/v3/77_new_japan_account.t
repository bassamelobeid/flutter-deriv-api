use strict;
use warnings;
use Test::More tests => 5;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my $t = build_mojo_test();

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
    my $token = BOM::Platform::SessionCookie->new(
        loginid => $vr_client->loginid,
        email   => $vr_client->email,
    )->token;
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    subtest 'create JP account' => sub {
        $t = $t->send_ok({json => \%client_details})->message_ok;
        my $res = decode_json($t->message->[1]);
        ok($res->{new_account_japan});
        test_schema('new_account_japan', $res);

        my $loginid = $res->{new_account_japan}->{client_id};
        like($loginid, qr/^JP\d+$/, "got JP client $loginid");
    };

    subtest 'no duplicate account - same email' => sub {
        $t = $t->send_ok({json => \%client_details})->message_ok;
        my $res = decode_json($t->message->[1]);

        is($res->{error}->{code},    'duplicate email', 'no duplicate account for JP');
        is($res->{new_account_real}, undef,             'NO account created');
    };

    subtest 'no duplicate - Name + DOB' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'test+test@binary.com',
            client_password => 'abc123',
            residence       => 'jp',
        });
        # authorize
        my $token = BOM::Platform::SessionCookie->new(
            loginid => $vr_client->loginid,
            email   => $vr_client->email,
        )->token;
        $t = $t->send_ok({json => {authorize => $token}})->message_ok;

        # create CR acc
        $t = $t->send_ok({json => \%client_details})->message_ok;
        my $res = decode_json($t->message->[1]);

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
    my $token = BOM::Platform::SessionCookie->new(
        loginid => $vr_client->loginid,
        email   => $vr_client->email,
    )->token;
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    # create JP real acc
    my %details = %client_details;
    $details{residence} = 'gb';
    $details{first_name} .= '-gb';

    subtest 'UK residence' => sub {
        $t = $t->send_ok({json => \%details})->message_ok;
        my $res = decode_json($t->message->[1]);

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
        my $token = BOM::Platform::SessionCookie->new(
            loginid => $vr_client->loginid,
            email   => $vr_client->email,
        )->token;
        $t = $t->send_ok({json => {authorize => $token}})->message_ok;

        # create JP real acc
        my %details = %client_details;
        $details{first_name} .= '-VR-nl';

        subtest 'VRTJ nl residence' => sub {
            $t = $t->send_ok({json => \%details})->message_ok;
            my $res = decode_json($t->message->[1]);

            is($res->{error}->{code},     'InvalidAccount',                                'NO VR nl residence');
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
        my $token = BOM::Platform::SessionCookie->new(
            loginid => $vr_client->loginid,
            email   => $vr_client->email,
        )->token;
        $t = $t->send_ok({json => {authorize => $token}})->message_ok;

        # create JP real acc
        my %details = %client_details;
        $details{first_name} .= '-au';

        subtest 'VRTC au residence' => sub {
            $t = $t->send_ok({json => \%details})->message_ok;
            my $res = decode_json($t->message->[1]);

            is($res->{error}->{code},     'InvalidAccount',                                'VR residence must be "jp"');
            is($res->{error}->{message},  'Sorry, account opening is unavailable.', 'VR jp only');
            is($res->{new_account_japan}, undef,                                    'NO account created');
        };
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
