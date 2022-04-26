#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;

use Date::Utility;
use BOM::User::Client;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;
use BOM::Config::PaymentAgent;
use BOM::User::Client::PaymentAgent;
use BOM::User;
use BOM::User::Password;
use BOM::Database::Model::OAuth;
use BOM::Test::Helper::ExchangeRates qw (populate_exchange_rates);

populate_exchange_rates();

subtest 'allow_paymentagent_withdrawal' => sub {

    #create client
    my $email = 'dummy' . rand(999) . '@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        residence      => 'in',                                                                # non blocked CFT country
        binary_user_id => $user->id,
        date_joined    => Date::Utility->new()->_minus_months(11)->datetime_yyyymmdd_hhmmss,
    });
    $client_usd->set_default_account('USD');
    $user->add_client($client_usd);

    #Create payment agent
    $email = 'dummy' . rand(999) . '@binary.com';
    my $user_agent = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $agent_name = 'Test Agent';
    my $agent_usd  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        residence      => 'in',     # non blocked CFT country
        place_of_birth => 'in',
    });
    $agent_usd->set_default_account('USD');
    $agent_usd->payment_agent({
        payment_agent_name    => $agent_name,
        currency_code         => 'USD',
        email                 => $email,
        information           => 'Test Info',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        target_country        => 'in',
    });
    $agent_usd->save;
    $user_agent->add_client($agent_usd);

    $agent_usd->payment_legacy_payment(
        currency     => 'USD',
        amount       => 1000,
        remark       => 'here is money',
        payment_type => 'ewallet',
    );

    my $validation_obj = BOM::Transaction::Validation->new({clients => [$client_usd]});
    my $allow_withdraw;

    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(0);

    subtest '0- virtual account' => sub {

        my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'VRTC',
            email          => $email,
            residence      => 'in',                                                                # non blocked CFT country
            binary_user_id => $user->id,
            date_joined    => Date::Utility->new()->_minus_months(11)->datetime_yyyymmdd_hhmmss,
        });
        $client_vr->set_default_account('USD');
        $user->add_client($client_vr);

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_vr);
        is $allow_withdraw, 'PaymentAgentVirtualClient', '0-1- VRTC account -> rejected';

        $client_usd->status->set('pa_withdrawal_explicitly_allowed', 'system', 'enable withdrawal through payment agent');
        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd);
        is $allow_withdraw, undef, '0-2- pa_withdrawal explicitely allowed -> payment agent withdrawal allowed';
        $client_usd->clear_status_and_sync_to_siblings('pa_withdrawal_explicitly_allowed');
    };

    subtest '1- No deposits or PA is the only deposit method -> payment agent withdrawal allowed' => sub {

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd);
        is $allow_withdraw, undef, '1-1- no deposits - allow PA withdrawal';

        # PA sends money to client
        $agent_usd->payment_account_transfer(
            toClient           => $client_usd,
            currency           => 'USD',
            amount             => 500,
            fees               => 0,
            is_agent_to_client => 1,
            gateway_code       => 'payment_agent_transfer',
            verification       => 'paymentagent_transfer',
        );
        $agent_usd->save;
        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd);
        is $allow_withdraw, undef, '1-2- PA is the only deposit method -> payment agent withdrawal allowed';
    };

    #create client
    my $email1 = 'dummy' . rand(999) . '@binary.com';
    my $user1  = BOM::User->create(
        email          => $email1,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_usd1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email1,
        residence      => 'in',                                                                # non blocked CFT country
        binary_user_id => $user1->id,
        date_joined    => Date::Utility->new()->_minus_months(11)->datetime_yyyymmdd_hhmmss,
    });
    $client_usd1->set_default_account('USD');
    $user1->add_client($client_usd1);

    subtest '2- visa - CFT NOT Blocked - ' => sub {

        $validation_obj = BOM::Transaction::Validation->new({clients => [$client_usd1]});

        #set the country of residence to a non blocked CFT country
        $client_usd1->residence('in');                                                             # non blocked CFT country
        $client_usd1->save();

        # PA sends money to client
        $agent_usd->payment_account_transfer(
            toClient           => $client_usd1,
            currency           => 'USD',
            amount             => 1,
            fees               => 0,
            is_agent_to_client => 1,
            gateway_code       => 'payment_agent_transfer',
            verification       => 'paymentagent_transfer',
        );

        $client_usd1->payment_doughflow(
            currency       => 'USD',
            amount         => 90,
            remark         => 'here is money',
            payment_type   => 'external_cashier',
            payment_method => 'VISA',
        );

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd1);
        is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '2-1- PaymentAgentWithdrawSameMethod';
    };

    subtest '3- visa - CFT blocked' => sub {

        # set the country of residence to a blocked CFT country
        $client_usd1->residence('ca');    #Canada
        $client_usd1->save();

        $client_usd1->payment_doughflow(
            currency       => 'USD',
            amount         => 101,
            remark         => 'here is money',
            payment_type   => 'external_cashier',
            payment_method => 'VISA',
        );

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd1);
        is $allow_withdraw, 'PaymentAgentUseOtherMethod', '3-1- PaymentAgentUseOtherMethod';

    };

    #create client
    my $email2 = 'dummy' . rand(999) . '@binary.com';
    my $user2  = BOM::User->create(
        email          => $email2,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_usd2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email2,
        residence      => 'in',                                                                # non blocked CFT country
        binary_user_id => $user2->id,
        date_joined    => Date::Utility->new()->_minus_months(11)->datetime_yyyymmdd_hhmmss,
    });
    $client_usd2->set_default_account('USD');
    $user2->add_client($client_usd2);

    subtest '4- MasterCard' => sub {

        $validation_obj = BOM::Transaction::Validation->new({clients => [$client_usd2]});

        $client_usd2->payment_doughflow(
            currency       => 'USD',
            amount         => 101,
            remark         => 'here is money',
            payment_type   => 'external_cashier',
            payment_method => 'MasterCard',
        );

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd2);
        is $allow_withdraw, 'PaymentAgentUseOtherMethod', '4-1- not traded so ask for justification/same withdrawal method';

    };

    #create client
    my $email3 = 'dummy' . rand(999) . '@binary.com';
    my $user3  = BOM::User->create(
        email          => $email3,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_usd3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email3,
        residence      => 'in',                                                                # non blocked CFT country
        binary_user_id => $user3->id,
        date_joined    => Date::Utility->new()->_minus_months(11)->datetime_yyyymmdd_hhmmss,
    });
    $client_usd3->set_default_account('USD');
    $user3->add_client($client_usd3);

    subtest '6- Reversible - Acquired (NOT ZingPay) - CFT NOT Blocked' => sub {

        $validation_obj = BOM::Transaction::Validation->new({clients => [$client_usd3]});

        $client_usd3->payment_doughflow(
            currency          => 'USD',
            amount            => 90,
            remark            => 'here is money',
            payment_type      => 'external_cashier',
            payment_processor => 'Acquired',
        );

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd3);
        is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '6-1- PaymentAgentWithdrawSameMethod';
    };

    subtest '7- Reversible - CardPay (NOT ZingPay) - CFT blocked' => sub {

        # set the country of residence to a blocked CFT country
        $client_usd3->residence('ca');    #Canada
        $client_usd3->save();

        $client_usd3->payment_doughflow(
            currency          => 'USD',
            amount            => 101,
            remark            => 'here is money',
            payment_type      => 'external_cashier',
            payment_processor => 'CardPay',
        );

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd3);
        is $allow_withdraw, 'PaymentAgentUseOtherMethod', '7-1- PaymentAgentUseOtherMethod';
    };

    #create client
    my $email4 = 'dummy' . rand(999) . '@binary.com';
    my $user4  = BOM::User->create(
        email          => $email4,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_usd4 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email4,
        residence      => 'in',                                                                # non blocked CFT country
        binary_user_id => $user4->id,
        date_joined    => Date::Utility->new()->_minus_months(11)->datetime_yyyymmdd_hhmmss,
    });
    $client_usd4->set_default_account('USD');
    $user4->add_client($client_usd4);

    subtest '8- Reversible - ZingPay' => sub {

        $validation_obj = BOM::Transaction::Validation->new({clients => [$client_usd4]});

        $client_usd4->payment_doughflow(
            currency          => 'USD',
            amount            => 60,
            remark            => 'here is money',
            payment_type      => 'ewallet',
            payment_processor => 'ZingPay',
        );

        # trade again so the sum of trades are more than 50% of last 6months deposits
        my $mock_client = Test::MockModule->new("BOM::User::Client");
        $mock_client->mock(get_sum_trades => sub { return 65; });

        $client_usd4->status->clear_age_verification;

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd4);
        is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '8-1-  PaymentAgentWithdrawSameMethod';

    };

    #create client
    my $email5 = 'dummy' . rand(999) . '@binary.com';
    my $user5  = BOM::User->create(
        email          => $email5,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_usd5 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email5,
        residence      => 'id',
        binary_user_id => $user5->id,
        date_joined    => Date::Utility->new()->_minus_months(11)->datetime_yyyymmdd_hhmmss,
    });
    $client_usd5->set_default_account('USD');
    $user5->add_client($client_usd5);

    subtest '9- Ireversible - withdrawal_supported' => sub {

        $validation_obj = BOM::Transaction::Validation->new({clients => [$client_usd5]});

        $client_usd5->payment_doughflow(
            currency          => 'USD',
            amount            => 101,                  # <200
            remark            => 'here is money',
            payment_type      => 'external_cashier',
            payment_processor => 'AirTM',
        );

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd5);
        is $allow_withdraw, 'PaymentAgentJustification', '9-1- no trade amount<200 - PaymentAgentWithdrawSameMethod';

        # sum of deposits : 101
        my $mock_client = Test::MockModule->new("BOM::User::Client");
        $mock_client->mock(get_sum_trades => sub { return 70; });

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd5);
        is $allow_withdraw, undef, '9-2- allow paymentagent withdrawal';

        $client_usd5->payment_doughflow(
            currency          => 'USD',
            amount            => 100,
            remark            => 'here is money',
            payment_type      => 'external_cashier',
            payment_processor => 'AirTM',
        );

        # sum of deposits became 101+100 = 201
        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd5);
        is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '9-3- amount>200';

    };

    #create client
    my $email6 = 'dummy' . rand(999) . '@binary.com';
    my $user6  = BOM::User->create(
        email          => $email6,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_usd6 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email6,
        residence      => 'id',
        binary_user_id => $user6->id,
        date_joined    => Date::Utility->new()->_minus_months(11)->datetime_yyyymmdd_hhmmss,
    });
    $client_usd6->set_default_account('USD');
    $user6->add_client($client_usd6);

    subtest '10- Ireversible - withdrawal option NOT available' => sub {

        $validation_obj = BOM::Transaction::Validation->new({clients => [$client_usd6]});

        $client_usd6->payment_doughflow(
            currency          => 'USD',
            amount            => 201,
            remark            => 'here is money',
            payment_type      => 'external_cashier',
            payment_processor => 'help2pay',
        );

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd6);
        is $allow_withdraw, 'PaymentAgentJustification', '10-1- not traded';

        my $mock_client = Test::MockModule->new("BOM::User::Client");
        $mock_client->mock(get_sum_trades => sub { return 120; });

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_usd6);
        is $allow_withdraw, undef, '10-2- allow paymentagent withdrawal';

    };

    #create client
    my $email7 = 'dummy' . rand(999) . '@binary.com';
    my $user7  = BOM::User->create(
        email          => $email7,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_crypto = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email7,
        binary_user_id => $user7->id,
    });
    $client_crypto->account('ETH');
    $user7->add_client($client_crypto);

    subtest '11- crypto' => sub {

        $validation_obj = BOM::Transaction::Validation->new({clients => [$client_crypto]});

        $client_crypto->payment_ctc(
            currency         => 'ETH',
            amount           => 10,
            crypto_id        => 1,
            address          => 'address1',
            transaction_hash => 'txhash1',
        );

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_crypto);
        is $allow_withdraw, 'PaymentAgentWithdrawSameMethod', '11-1- not traded so ask PaymentAgentWithdrawSameMethod';

        my $mock_client = Test::MockModule->new("BOM::User::Client");
        $mock_client->mock(get_sum_trades => sub { return 80; });

        $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client_crypto);
        is $allow_withdraw, undef, '11-2- allow paymentagent withdrawal';
    };

};

done_testing();
