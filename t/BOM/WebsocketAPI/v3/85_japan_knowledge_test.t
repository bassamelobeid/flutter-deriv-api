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

subtest 'Japan Knowledge Test' => sub {

    my ($vr_client, $token, $jp_loginid);
    subtest 'create VRTJ & JP client' => sub {
        # create VR acc
        my $acc  = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email           => 'test@binary.com',
                    client_password => 'abc123',
                    residence       => 'jp',
                },
                email_verified => 1
            });
        $vr_client = $acc->{client};
        print "VRTJ [" . $vr_client->loginid . "]..\n";

        # authorize
        $token = BOM::Platform::SessionCookie->new(
            loginid => $vr_client->loginid,
            email   => $vr_client->email,
        )->token;
        print "token [$token]...\n\n";
        $t = $t->send_ok({json => {authorize => $token}})->message_ok;

        # create JP acc
        $t = $t->send_ok({json => \%client_details})->message_ok;
        my $res = decode_json($t->message->[1]);
        $jp_loginid = $res->{new_account_japan}->{client_id};

        print "JP loginid [$jp_loginid]\n\n";
    };

    use Data::Dumper;

    subtest 'knowledge test' => sub {
        $t = $t->send_ok({json => {get_settings => 1}})->message_ok;
        my $res = decode_json($t->message->[1]);
        print "get_settings res[" . Dumper($res) . "]\n\n";

        is $res->{get_settings}->{jp_account_status}->{status}, 'jp_knowledge_test_pending';

        subtest 'knowledge test taken' => sub {
            $t = $t->send_ok({json => {
                jp_knowledge_test   => 1,
                score               => 10,
                status              => 'fail',
            }})->message_ok;
            my $res = decode_json($t->message->[1]);
            my $epoch = $res->{jp_knowledge_test}->{test_taken_epoch};
            like $epoch, qr/^\d+$/, "test taken time is epoch: $epoch";

        };

    };
};


$t->finish_ok;
