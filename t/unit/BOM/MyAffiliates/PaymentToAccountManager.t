use strict;
use warnings;
use Test::More;
use Test::Deep;
use Data::Dumper qw( Dumper );
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Date::Utility;
use BOM::MyAffiliates::PaymentToAccountManager;

subtest '_get_month_from_transaction' => sub {

    my $input    = {"OCCURRED" => "2022-12-09"};
    my @expected = ("Dec 2022", "12", "2022");
    my @output   = BOM::MyAffiliates::PaymentToAccountManager::_get_month_from_transaction($input);
    cmp_bag(\@output, \@expected, "transaction has an occurred date");

    $input    = {};
    @expected = ("", "", "");
    @output   = BOM::MyAffiliates::PaymentToAccountManager::_get_month_from_transaction($input);
    cmp_bag(\@output, \@expected, "transaction date is in wrong format");

};

subtest '_get_loginid_from_txn' => sub {

    my $input = {
        "USER_PAYMENT_TYPE" => {
            "PAYMENT_DETAILS" => {
                "DETAIL" => [{
                        "DETAIL_NAME"  => "bom_id",
                        "DETAIL_VALUE" => " CR15609  "
                    }]}}};
    my $expected = "CR15609";
    my $output   = BOM::MyAffiliates::PaymentToAccountManager::_get_loginid_from_txn($input);
    is($output, $expected, "Transcation contains payment details");

    $input    = {"USER_PAYMENT_TYPE" => {"PAYMENT_DETAILS" => {"DETAIL" => 0}}};
    $expected = undef;
    $output   = BOM::MyAffiliates::PaymentToAccountManager::_get_loginid_from_txn($input);
    is($output, $expected, "Transaction has no payment details");

};

subtest '_get_csv_line_from_txn' => sub {

    my $input    = {"USER_PAYMENT_TYPE" => {"PAYMENT_DETAILS" => {"DETAIL" => 0}}};
    my $expected = "Could not extract BOM loginid from transaction. Full transaction details: ";
    throws_ok { BOM::MyAffiliates::PaymentToAccountManager::_get_csv_line_from_txn($input) } qr/$expected/, "Transaction has no loginid";

    my $mock_client;
    my $mocked_bom_client = Test::MockModule->new("BOM::User::Client")->redefine("get_instance", sub { return $mock_client });

    $input = {
        "USER_PAYMENT_TYPE" => {
            "PAYMENT_DETAILS" => {
                "DETAIL" => [{
                        "DETAIL_NAME"  => "bom_id",
                        "DETAIL_VALUE" => " CR15609  "
                    }]}}};
    $mock_client = undef;
    $expected    = 'Could not instantiate client from extracted BOM loginid. Full transaction details: ';
    throws_ok { BOM::MyAffiliates::PaymentToAccountManager::_get_csv_line_from_txn($input) } qr/$expected/, "No client with specifiedn loginid";

    $input = {
        "USER_PAYMENT_TYPE" => {
            "PAYMENT_DETAILS" => {
                "DETAIL" => [{
                        "DETAIL_NAME"  => "bom_id",
                        "DETAIL_VALUE" => " CR15609  "
                    }]}
        },
        "AMOUNT" => 10
    };
    $mock_client = {};
    $expected    = 'Amount\[' . $input->{"AMOUNT"} . '\] is invalid. Full transaction details: ';
    throws_ok { BOM::MyAffiliates::PaymentToAccountManager::_get_csv_line_from_txn($input) } qr/$expected/, "Transaction amount is invalid";

    $input = {
        "USER_PAYMENT_TYPE" => {
            "PAYMENT_DETAILS" => {
                "DETAIL" => [{
                        "DETAIL_NAME"  => "bom_id",
                        "DETAIL_VALUE" => " CR15609  "
                    }]}
        },
        "AMOUNT" => -10
    };
    $mock_client = Test::MockObject->new();
    $mock_client->mock("currency", sub { "USD" });
    $expected = 'Could not extract month from transaction. Full transaction details: ';
    throws_ok { BOM::MyAffiliates::PaymentToAccountManager::_get_csv_line_from_txn($input) } qr/$expected/, "Time of transaction not specified";

    my $mock_db_mapper;
    my $mock_affiliates_reporter = Test::MockModule->new("BOM::MyAffiliates::Reporter")->redefine("database_mapper", sub { return $mock_db_mapper });

    $input = {
        "USER_PAYMENT_TYPE" => {
            "PAYMENT_DETAILS" => {
                "DETAIL" => [{
                        "DETAIL_NAME"  => "bom_id",
                        "DETAIL_VALUE" => " CR15609  "
                    }]}
        },
        "AMOUNT"   => -10,
        "OCCURRED" => "2022-12-09"
    };
    $mock_client = Test::MockObject->new();
    my $landing_company_mock = Test::MockObject->new();
    $landing_company_mock->mock("name", sub { "Deriv (SVG) LLC" });
    $mock_client->mock("landing_company", sub { return $landing_company_mock; });
    $mock_client->mock("currency",        sub { "SGD" });
    $mock_client->mock("broker_code",     sub { "CR" });
    $mock_db_mapper = Test::MockObject->new();
    $mock_db_mapper->mock("get_monthly_exchange_rate", sub { return [[10]] });
    $expected = 'CR15609,credit,affiliate_reward,SGD,1.00,"Payment from Deriv (SVG) LLC Dec 2022"';
    my $output = BOM::MyAffiliates::PaymentToAccountManager::_get_csv_line_from_txn($input);
    is($output, $expected, "CSV generated for non US currency");

    $mock_client          = {};
    $landing_company_mock = {};

    $landing_company_mock = Test::MockObject->new();
    $landing_company_mock->mock("name", sub { "Deriv Investments (Europe) Limited" });
    $mock_client = Test::MockObject->new();
    $mock_client->mock("landing_company", sub { return $landing_company_mock; });
    $mock_client->mock("currency",        sub { "EUR" });
    $mock_client->mock("broker_code",     sub { "MF" });
    $mock_db_mapper = Test::MockObject->new();
    $mock_db_mapper->mock("get_monthly_exchange_rate", sub { return [[10]] });
    $expected = 'CR15609,credit,affiliate_reward,EUR,1.00,"Payment from Deriv Investments (Europe) Limited Dec 2022"';
    $output   = BOM::MyAffiliates::PaymentToAccountManager::_get_csv_line_from_txn($input);
    is($output, $expected, "CSV generated for non US currency");
};

subtest '_get_file_loc' => sub {

    my $instance = BOM::MyAffiliates::PaymentToAccountManager->new(
        from => Date::Utility->new("2022-12-9"),
        to   => Date::Utility->new("2022-12-12"));

    my $input    = "PARSE_ERRORS";
    my $expected = "/tmp/affiliate_payment_PARSE_ERRORS_20221209000000_20221212000000.txt";
    my $output   = $instance->_get_file_loc($input);
    is($output, $expected, "File location for error reports");

    $input    = "RECON";
    $expected = "/tmp/affiliate_payment_RECON_20221209000000_20221212000000.csv";
    $output   = $instance->_get_file_loc($input);
    is($output, $expected, "File location for non-error reports");
};

subtest '_split_txn_by_landing_company' => sub {
    my $mock_lc;
    my $mock_lc_register = Test::MockModule->new("LandingCompany::Registry")->redefine("by_loginid", sub { $mock_lc });
    my $input            = [{
            "USER_PAYMENT_TYPE" => {
                "PAYMENT_DETAILS" => {
                    "DETAIL" => [{
                            "DETAIL_NAME"  => "bom_id",
                            "DETAIL_VALUE" => " CR15609  "
                        }]}
            },
            "AMOUNT"   => -10,
            "OCCURRED" => "2022-12-09"
        },
        {
            "USER_PAYMENT_TYPE" => {"PAYMENT_DETAILS" => {"DETAIL" => [{}]}},
            "AMOUNT"            => -10,
            "OCCURRED"          => "2022-12-09"
        }];
    my $expected = {
        'LOGIN_EXTRACTION_ERRORS' => [{
                "USER_PAYMENT_TYPE" => {"PAYMENT_DETAILS" => {"DETAIL" => [{}]}},
                "AMOUNT"            => -10,
                "OCCURRED"          => "2022-12-09"
            }
        ],
        'maltainvest' => [{
                "USER_PAYMENT_TYPE" => {
                    "PAYMENT_DETAILS" => {
                        "DETAIL" => [{
                                "DETAIL_NAME"  => "bom_id",
                                "DETAIL_VALUE" => " CR15609  "
                            }]}
                },
                "AMOUNT"   => -10,
                "OCCURRED" => "2022-12-09"
            }]};
    $mock_lc = Test::MockObject->new();
    $mock_lc->mock("short", sub { "maltainvest" });
    my $output = BOM::MyAffiliates::PaymentToAccountManager::_split_txn_by_landing_company(@$input);
    cmp_deeply($output, $expected, "Transactions are split by landing company");
};

done_testing;
