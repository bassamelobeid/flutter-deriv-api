use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::Exception;
use Test::MockModule;

use BOM::Rules::Engine;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
BOM::Test::Helper::Client::top_up($client, $client->currency, 10);

my $rule_engine               = BOM::Rules::Engine->new(client => $client);
my $payment_validating_action = 'validate_affiliate_payment';
my $currency                  = 'USD';
my $signed_amount             = 1;

subtest 'validate_bypassing_rules' => sub {
    ##
    $client->status->set('cashier_locked', 'test', 'test');
    $client->set_default_account('USD');
    lives_ok {
        $client->validate_payment(
            action_to_validate => $payment_validating_action,
            currency           => $currency,
            amount             => $signed_amount,
            rule_engine        => $rule_engine
        )
    }
    'bypass cashier.is_not_locked';
    ##
    $signed_amount = -1;
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(is_financial_assessment_complete => 0);
    lives_ok {
        $client->validate_payment(
            action_to_validate => $payment_validating_action,
            currency           => $currency,
            amount             => $signed_amount,
            rule_engine        => $rule_engine
        )
    }
    'bypass financial_asssessment.completed';
    ##
    my $mock_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    $mock_documents->redefine(expired => 1);
    lives_ok {
        $client->validate_payment(
            action_to_validate => $payment_validating_action,
            currency           => $currency,
            amount             => $signed_amount,
            rule_engine        => $rule_engine
        )
    }
    'bypass client.documents_not_expired';
    ##
    my $lc_check_max_turnover = 0;
    my $mock_landing_company  = Test::MockModule->new('LandingCompany');
    $mock_landing_company->redefine(check_max_turnover_limit_is_set => sub { $lc_check_max_turnover });

    my $country_config = {
        need_set_max_turnover_limit => 1,
        ukgc_funds_protection       => 1,
    };
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(countries_list => sub { return +{$client->residence => $country_config}; });

    lives_ok {
        $client->validate_payment(
            action_to_validate => $payment_validating_action,
            currency           => $currency,
            amount             => $signed_amount,
            rule_engine        => $rule_engine
        )
    }
    'bypass client.check_max_turnover_limit';
    ##
    my $excluded_until = '2000-01-02';
    $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine('get_self_exclusion_until_date' => sub { return $excluded_until });
    lives_ok {
        $client->validate_payment(
            action_to_validate => $payment_validating_action,
            currency           => $currency,
            amount             => $signed_amount,
            rule_engine        => $rule_engine
        )
    }
    'bypass self_exclusion.not_self_excluded';
    ##
    $client->status->set('unwelcome', 'test', 'test');
    lives_ok {
        $client->validate_payment(
            action_to_validate => $payment_validating_action,
            currency           => $currency,
            amount             => $signed_amount,
            rule_engine        => $rule_engine
        )
    }
    'bypass client.no_unwelcome_status';
    ##
    $mock_client->redefine(fixed_max_balance => 10);
    $signed_amount = 1;
    lives_ok {
        $client->validate_payment(
            action_to_validate => $payment_validating_action,
            currency           => $currency,
            amount             => $signed_amount,
            rule_engine        => $rule_engine
        )
    }
    'bypass deposit.total_balance_limits';
    ##disable account should fail.
    $client->status->set('disabled', 'test', 'test');
    is_deeply exception {
        $client->validate_payment(
            action_to_validate => $payment_validating_action,
            currency           => $currency,
            amount             => $signed_amount,
            rule_engine        => $rule_engine
        )
    },
        {
        message_to_client => 'Your account is disabled.',
        code              => 'DisabledAccount',
        params            => [$client->loginid]
        },
        'Error for disabled client';
};

done_testing();
