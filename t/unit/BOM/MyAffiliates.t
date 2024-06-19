use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;

use BOM::MyAffiliates;

subtest get_token => sub {

    my ($mock_user_info, $mock_token, $input, $expected);
    my $mock_myaffiliates = Test::MockModule->new("WebService::MyAffiliates");
    $mock_myaffiliates->redefine(get_user     => sub { return $mock_user_info });
    $mock_myaffiliates->redefine(encode_token => sub { return $mock_token });

    my $myaffiliates = BOM::MyAffiliates->new();

    $input    = undef;
    $expected = "Must pass affiliate_id to get_token";
    throws_ok { $myaffiliates->get_token() } qr/$expected/, "No affiliate_id passed";

    $input          = {"affiliate_id"  => "abcd1234"};
    $mock_user_info = {"SUBSCRIPTIONS" => {"SUBSCRIPTION" => {PLAN_NAME => 'NOT VALID PLAN NAME'}}};
    $expected =
          'Unable to get Setup ID for affiliate\['
        . $input->{affiliate_id}
        . '\], plan\['
        . $mock_user_info->{SUBSCRIPTIONS}{SUBSCRIPTION}{PLAN_NAME} . '\]';
    throws_ok { $myaffiliates->get_token($input) } qr/$expected/, "Affiliates did not return an valid plan";

    $input          = {"affiliate_id"  => "abcd1234"};
    $mock_user_info = {"SUBSCRIPTIONS" => {"SUBSCRIPTION" => {"PLAN_NAME" => "Revenue Share"}}};
    $mock_token     = {"USER"          => {"TOKEN"        => "SAMPLE_TOKEN1234"}};
    $expected       = $mock_token->{USER}{TOKEN};
    is $myaffiliates->get_token($input), $expected, "Affiliate token fetched sucessfully";
    $mock_myaffiliates->unmock_all();
};

subtest is_subordinate_affiliate => sub {
    my ($mock_user_info, $expected, $input);
    my $mock_myaffiliates = Test::MockModule->new("WebService::MyAffiliates");
    $mock_myaffiliates->redefine(get_user => sub { return $mock_user_info });

    my $myaffiliates = BOM::MyAffiliates->new();

    $input          = "dummy_affiliate_id";
    $mock_user_info = {
        "USER_VARIABLES" => {
            "VARIABLE" => [{
                    "NAME"  => "affiliate_id",
                    "VALUE" => 'dummy_affiliate_id'
                }]}};
    $expected = undef;
    is $myaffiliates->is_subordinate_affiliate($input), $expected, "Affiliate is not a subordinate";

    $input          = "dummy_affiliate_id";
    $mock_user_info = {
        "USER_VARIABLES" => {
            "VARIABLE" => [{
                    "NAME"  => "subordinate",
                    "VALUE" => 1
                }]}};
    $expected = 1;
    is $myaffiliates->is_subordinate_affiliate($input), $expected, "Affiliate is subordinate";
    $mock_myaffiliates->unmock_all();
};

subtest get_myaffiliates_id_for_promo_code => sub {
    my ($mock_user_info, $expected, $input);
    my $mock_myaffiliates = Test::MockModule->new("WebService::MyAffiliates");
    $mock_myaffiliates->redefine(get_users => sub { return $mock_user_info });

    my $myaffiliates = BOM::MyAffiliates->new();

    $input          = "VALID_PROMO";
    $mock_user_info = {"USER" => undef};
    $expected       = undef;
    is $myaffiliates->get_myaffiliates_id_for_promo_code($input), $expected, "No affiliates with specified promocode";

    $input          = "VALID_PROMO";
    $mock_user_info = {"USER" => []};
    $expected       = 'Search returned more than one user';
    throws_ok { $myaffiliates->get_myaffiliates_id_for_promo_code($input) } qr/$expected/, "Promo code should be assigned to single affiliate";

    $input          = "VALID_PROMO";
    $mock_user_info = {"USER" => {"ID" => "NON_NUMERIC_AFFILIATE_ID"}};
    $expected =
          'ID is not a number\? \[id:'
        . $mock_user_info->{USER}{ID}
        . '\] while searching for variable \[betonmarkets_promo_code => %;'
        . $input . ';%\]';
    throws_ok { $myaffiliates->get_myaffiliates_id_for_promo_code($input) } qr/$expected/, "Affiliate id is not numeric";

    $input          = "VALID_PROMO";
    $mock_user_info = {"USER" => {"ID" => "124389453984"}};
    $expected       = $mock_user_info->{USER}{ID};
    is $myaffiliates->get_myaffiliates_id_for_promo_code($input), $expected, "Affiliate id fetched based on promo code";
    $mock_myaffiliates->unmock_all();
};

subtest fetch_account_transactions => sub {
    my ($mock_transaction_info, $input, $expected);
    my $mock_myaffiliates = Test::MockModule->new("WebService::MyAffiliates");
    $mock_myaffiliates->redefine(get_user_transactions => sub { return $mock_transaction_info });

    my $myaffiliates = BOM::MyAffiliates->new();

    $mock_transaction_info = {"TRANSACTION" => undef};
    $input                 = {
        "FROM_DATE" => "2022-10-9",
        "TO_DATE"   => "2022-11-9"
    };
    $expected = 'No transactions found for ' . $input->{FROM_DATE} . ' to ' . $input->{TO_DATE};
    throws_ok { $myaffiliates->fetch_account_transactions($input) } qr/$expected/, 'No affiliate transaction within given time period';

    $mock_transaction_info = {
        "TRANSACTION" => {
            "TRANSACTION_ID"    => "123456",
            "USER_PAYMENT_TYPE" => {"PAYMENT_TYPE_ID" => 7},
            "EMAIL"             => 'dummy@affiliate.com'
        }};
    $input = {
        "FROM_DATE" => "2022-10-9",
        "TO_DATE"   => "2022-11-09"
    };
    $expected = [$mock_transaction_info->{TRANSACTION}];
    my @got = $myaffiliates->fetch_account_transactions($input);
    cmp_deeply(\@got, $expected, "MyAffiliates returns a single transcation");

    $mock_transaction_info = {
        "TRANSACTION" => [{
                "TRANSACTION_ID"    => "123456",
                "USER_PAYMENT_TYPE" => {"PAYMENT_TYPE_ID" => 7},
                "EMAIL"             => 'dummy@affiliate.com'
            },
            {
                "TRANSACTION_ID"    => "156",
                "USER_PAYMENT_TYPE" => {"PAYMENT_TYPE_ID" => 5},
                "EMAIL"             => 'dummy@affiliate.com'
            },
            {
                "TRANSACTION_ID"    => "9898",
                "USER_PAYMENT_TYPE" => {"PAYMENT_TYPE_ID" => 7},
                "EMAIL"             => 'dummy24@affiliate.com'
            },
            {
                "TRANSACTION_ID"    => "34376",
                "USER_PAYMENT_TYPE" => {"PAYMENT_TYPE_ID" => 2},
                "EMAIL"             => 'dummy12@affiliate.com'
            }]};
    $input = {
        "FROM_DATE" => "2022-10-9",
        "TO_DATE"   => "2022-11-09"
    };
    $expected = [{
            "TRANSACTION_ID"    => "123456",
            "USER_PAYMENT_TYPE" => {"PAYMENT_TYPE_ID" => 7},
            "EMAIL"             => 'dummy@affiliate.com'
        },
        {
            "TRANSACTION_ID"    => "9898",
            "USER_PAYMENT_TYPE" => {"PAYMENT_TYPE_ID" => 7},
            "EMAIL"             => 'dummy24@affiliate.com'
        }

    ];
    @got = $myaffiliates->fetch_account_transactions($input);
    cmp_deeply(\@got, $expected, "Returns affiliate transactions with 'to Binary account' transactions");
    $mock_myaffiliates->unmock_all();
};

done_testing;
