use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::MockModule;
use LandingCompany::Registry;

use BOM::Config::AccountType::Registry;
use Brands;

subtest 'registry' => sub {

    subtest 'load data' => sub {
        my $mock_config = Test::MockModule->new('BOM::Config');
        my $mock_data;
        $mock_config->redefine(account_types => sub { $mock_data });

        $mock_data = {groups => {test_group => {services => ['dummy service']}}};

        like exception { BOM::Config::AccountType::Registry::load_data() }, qr/Invalid services found in group test_group: dummy service/,
            'Correct error for invalid service name';

        $mock_data->{groups}->{test_group}->{services} = ['trade'];
        $mock_data->{categories} = {
            test_category => {
                broker_codes => {xyz => ['XYZ']},
                groups       => ['dummy_group']}};
        like exception { BOM::Config::AccountType::Registry::load_data() },
            qr/Unknown group dummy_group appeared in the account category test_category/, 'Correct error for invalid group name';
        my $test_category = $mock_data->{categories}->{test_category};
        $test_category->{groups} = ['test_group'];

        like exception { BOM::Config::AccountType::Registry::load_data() },
            qr/Invalid landing company xyz in account category test_category 's broker codes/, 'Correct error for invalid landing company name';
        $test_category->{broker_codes} = {svg => ['XYZ']};

        $test_category->{account_types} = {
            test_account_type => {
                broker_codes => {xyz => ['XYZ']},
                groups       => ['dummy_group']}};
        like exception { BOM::Config::AccountType::Registry::load_data() },
            qr/Unknown group dummy_group appeared in the account type test_category-test_account_type/, 'Correct error for invalid group name';
        my $test_account_type = $test_category->{account_types}->{test_account_type};
        $test_account_type->{groups} = ['test_group'];

        like exception { BOM::Config::AccountType::Registry::load_data() },
            qr/Invalid landing company xyz in account type test_category-test_account_type/, 'Correct error for invalid landing company name';

        $mock_config->unmock_all;
        # load the main config file
        is exception { BOM::Config::AccountType::Registry::load_data() }, undef, 'No error loading the main config file';
    };

    my $config = BOM::Config::account_types();

    for my $group_name (keys $config->{groups}->%*) {
        my $group_config = $config->{groups}->{$group_name};
        for my $service ($group_config->{services}->@*) {
            ok BOM::Config::AccountType::Group::SERVICES->{$service}, "Serivice $service in group $group_name is valid";
        }

        ok my $group = BOM::Config::AccountType::Registry->group_by_name($group_name), "Group $group_name object is found in registry";
        isa_ok $group, 'BOM::Config::AccountType::Group', "Group $group_name object type is correct";

        cmp_deeply $group->services, bag($group_config->{services}->@*), "Group $group_name services are loaded correctly";
    }

    my %groups_used;
    my %registered_categories = BOM::Config::AccountType::Registry->all_categories();
    cmp_deeply [keys $config->{categories}->%*], bag(keys %registered_categories), 'All caregories are registered';
    for my $category_name (keys $config->{categories}->%*) {
        ok my $category = BOM::Config::AccountType::Registry->category_by_name($category_name), "Category $category_name object is found";
        isa_ok $category, 'BOM::Config::AccountType::Category', "Category $category_name object type is correct";

        my $category_config = $config->{categories}->{$category_name};
        is_deeply $category->broker_codes, $category_config->{broker_codes} // {}, "Group $category_name boker codes are correct";
        cmp_deeply [map { $_->name } $category->groups->@*], bag($category_config->{groups}->@*),
            "Caterogy $category_name groups are correctly loaded"
            or warn explain {
            obj    => [map { $_->name } $category->groups->@*],
            config => $category_config->{groups}};

        $groups_used{$_} = 1 for $category_config->{groups}->@*;

        for my $type_name (keys $category_config->{account_types}->%*) {
            ok my $account_type = $category->account_types->{$type_name}, "Account type $category_name-$type_name object is found";
            isa_ok $account_type, 'BOM::Config::AccountType', "Account type $category_name-$type_name object type is correct";
            is(BOM::Config::AccountType::Registry->account_type_by_name($type_name),
                $account_type, "Account type $category_name-$type_name is found in registry");

            my $type_config = $category_config->{account_types}->{$type_name};

            cmp_deeply [map { $_->name } $account_type->groups->@*], bag($type_config->{groups}->@*, $category_config->{groups}->@*),
                "Account type $category_name-$type_name 's groups are correctly loaded";

            my $expected_brokers = keys $type_config->{broker_codes}->%* ? $type_config->{broker_codes} : $category->broker_codes;
            is_deeply $account_type->broker_codes, $expected_brokers, "Account type $category_name-$type_name 's broker codes are correct";

            $groups_used{$_} = 1 for $type_config->{groups}->@*;
        }
    }

    cmp_deeply [keys $config->{groups}->%*], bag(keys %groups_used), 'All groups are used in account types and categories';

    subtest 'find broker code' => sub {
        like exception { BOM::Config::AccountType::Registry->find_broker_code() }, qr/Broker code is missing/,
            'Correct error for missing broker code';

        my %args = (broker => 'CR');
        like exception { BOM::Config::AccountType::Registry->find_broker_code(%args) },
            qr/Cannot find the broke code without a category or an account type name/, 'Correct error for missing category and account type';

        $args{category} = 'trading';
        is(BOM::Config::AccountType::Registry->find_broker_code(%args), 1, 'CR found in trading category');

        $args{category} = 'wallet';
        is(BOM::Config::AccountType::Registry->find_broker_code(%args), 0, 'CR not found in wallet category');

        delete $args{category};
        $args{account_type} = 'crypto';
        is(BOM::Config::AccountType::Registry->find_broker_code(%args), 0, 'CR not found in crypto account type');

        $args{account_type} = 'standard';
        is(BOM::Config::AccountType::Registry->find_broker_code(%args), 1, 'CR found in standard account type');

        $args{account_type} = 'binary';
        is(BOM::Config::AccountType::Registry->find_broker_code(%args), 1, 'CR found in standard account type');

        $args{category} = 'wallet';
        is(BOM::Config::AccountType::Registry->find_broker_code(%args), 0, 'CR not found in wallet category + standard account type');
    };
};

subtest 'Group class' => sub {
    like exception { BOM::Config::AccountType::Group->new() }, qr/Group name is missing/, 'Correct error with empty args';

    my %args = (name => 'group1');
    is exception { BOM::Config::AccountType::Group->new(%args) }, undef, 'No error with name only';

    $args{services} = [qw/trade dummy/];
    like exception { BOM::Config::AccountType::Group->new(%args) }, qr/Invalid services found in group group1: dummy/,
        'Correct error with invalid service name';

    my $group;
    $args{services} = [qw/trade fiat_cashier/];
    is exception { $group = BOM::Config::AccountType::Group->new(%args) }, undef, 'No error with valid services';

    is $group->name, 'group1', 'Group name is correct';
    cmp_deeply $group->services, bag(qw/trade fiat_cashier/), 'Group services are correct';

};

subtest 'category class' => sub {
    like exception { BOM::Config::AccountType::Category->new() }, qr/Category name is missing/, 'Correct error with empty args';

    my %args = (
        name   => 'my_category',
        brands => ['dummy-brand']);
    like exception { BOM::Config::AccountType::Category->new(%args) }, qr/Invalid brand name dummy-brand in account category my_category/,
        'Correct error for invalid brand';

    $args{brands} = ['binary'];
    $args{groups} = ['dummy'];
    like exception { BOM::Config::AccountType::Category->new(%args) }, qr/Invalid group in account category my_category/,
        'Correct error for invalid group';

    $args{groups}       = [BOM::Config::AccountType::Registry->group_by_name('trader')];
    $args{broker_codes} = {dummy_company => ['CRW']};
    like exception { BOM::Config::AccountType::Category->new(%args) },
        qr/Invalid landing company dummy_company in account category my_category/, 'Correct error for invalid landing company';

    $args{broker_codes}  = {svg   => ['CRW']};
    $args{account_types} = {type1 => 1};
    like exception { BOM::Config::AccountType::Category->new(%args) }, qr/Invalid object for the account type type1 in category my_category/,
        'Correct error for invalid account type object';

    my $account_type = BOM::Config::AccountType->new(
        name     => 'my_type',
        category => BOM::Config::AccountType::Registry->category_by_name('wallet'),
    );
    $args{account_types} = {type1 => $account_type};
    like exception { BOM::Config::AccountType::Category->new(%args) },
        qr/Incorrect account type name type1 in category my_category - correct name is: my_type/,
        'Correct error for invalid account type name';

    $args{account_types} = {my_type => $account_type};
    like exception { BOM::Config::AccountType::Category->new(%args) },
        qr/Invalid category name wallet found in account type my_type. The expected category name was my_category/,
        'Correct error for mismatching accont type category';

    my $mock_account_type = Test::MockModule->new('BOM::Config::AccountType');
    $mock_account_type->redefine(category_name => 'my_category');
    my $category;
    ok $category = BOM::Config::AccountType::Category->new(%args), 'Category object is successfully created';
    is $category->name, 'my_category', 'name is correct';
    cmp_bag $category->brands, ['binary'], 'brand is correct';
    is_deeply $category->broker_codes,  {svg     => ['CRW']},       'broker codes are correct';
    is_deeply $category->account_types, {my_type => $account_type}, 'account types are correct';

    $mock_account_type->unmock_all;
};

subtest 'account type class' => sub {
    like exception { BOM::Config::AccountType->new() }, qr/Account type name is missing/, 'Correct error with empty args';

    my %args = (
        name => 'my_type',
    );
    like exception { BOM::Config::AccountType->new(%args) }, qr/Category is missing in account type my_type/, 'Correct error for missing category';

    $args{category} = 'dummy';
    like exception { BOM::Config::AccountType->new(%args) }, qr/Invalid category object in account type my_type/,
        'Correct error for invalid category';

    my $account_type;
    $args{category} = BOM::Config::AccountType::Registry->category_by_name('wallet');
    ok $account_type = BOM::Config::AccountType->new(%args), 'Account type created with the minimum args required';

    is $account_type->name,                           'my_type',                                                      'Name is correct';
    is $account_type->category_name,                  'wallet',                                                       'Category name is correct';
    is $account_type->category,                       BOM::Config::AccountType::Registry->category_by_name('wallet'), 'Category object is correct';
    is $account_type->linkable_to_different_currency, 0, 'it is not linkable to a different currency';

    is_deeply $account_type->brands,   ['deriv'], 'Brands are the same as the category';
    is_deeply $account_type->groups,   [],        'Groups are empty';
    is_deeply $account_type->services, [],        'Services are empty (no group)';
    is_deeply $account_type->broker_codes,
        {
        svg         => ['CRW'],
        maltainvest => ['MFW'],
        virtual     => ['VRW'],
        dsl         => ['CRA'],
        },
        'Broker codes are the same as the category';
    is_deeply $account_type->linkable_wallet_types,             [], 'No linkable wallet types';
    is_deeply $account_type->currencies,                        [], 'No limited currency';
    is_deeply $account_type->currency_types,                    [], 'Currency type is not limited';
    is_deeply $account_type->currencies_by_landing_company, {}, 'Currency is not limited by landing company';

    # other args
    $args{broker_codes} = {dummy_company => ['XYZ']};
    like exception { BOM::Config::AccountType->new(%args) },
        qr/Invalid landing company dummy_company in account type wallet-my_type/, 'Correct error for invalid landing company';

    $args{broker_codes} = {svg => ['XYZ']};
    $args{groups}       = ['dummy'];
    like exception { BOM::Config::AccountType->new(%args) }, qr/Invalid group in account type wallet-my_type/, 'Correct error for invalid group';

    $args{groups}                = [BOM::Config::AccountType::Registry->group_by_name('wallet')];
    $args{linkable_wallet_types} = ['dummy'];
    like exception { BOM::Config::AccountType->new(%args) },
        qr/Invalid linkable wallet type dummy in account type wallet-my_type/, 'Correct error for invalid linkable wallet type';

    $args{linkable_wallet_types} = ['all'];
    $args{currencies}            = ['XYZ'];
    like exception { BOM::Config::AccountType->new(%args) },
        qr/Unknown currency XYZ in account type wallet-my_type 's limited correncies/,
        'Correct error for invalid currency - all wallets are accepted';

    $args{linkable_wallet_types} = [qw/paymentagent paymentagent_client/];
    $args{currencies}            = [qw/USD BTC/];
    $args{currency_types}        = ['xyz'];
    like exception { BOM::Config::AccountType->new(%args) },
        qr/Unknown currency type xyz in account type wallet-my_type 's limited currency types/, 'Correct error for invalid currency';

    $args{currency_types}                = ['fiat', 'crypto'];
    $args{currencies_by_landing_company} = {dummy_company => []};
    like exception { BOM::Config::AccountType->new(%args) }, qr/Invalid landing company dummy_company/, 'Correct error for invalid landing company';

    $args{currencies_by_landing_company} = {maltainvest => ['BTC']};
    like exception { BOM::Config::AccountType->new(%args) },
        qr/Invalid currency BTC in account type wallet-my_type 's landing company limited currencies for maltainvest/,
        'Correct error for currency not supported by landing company';

    $args{currencies_by_landing_company}  = {svg => ['BTC']};
    $args{linkable_wallet_types}          = ['virtual'];
    $args{linkable_to_different_currency} = 1;
    ok $account_type = BOM::Config::AccountType->new(%args), 'Account type created with full args';

    my %expected = (%args, services => ['link_to_accounts']);
    is_deeply($account_type->$_, $expected{$_}, "Value of $_ is correct") for keys %expected;
};

subtest 'validate landing companies and broker codes' => sub {
    my %all_categories = BOM::Config::AccountType::Registry->all_categories();
    for my $category_name (keys %all_categories) {
        my $category = $all_categories{$category_name};
        for my $type_name (keys $category->account_types->%*) {
            my $account_type = $category->account_types->{$type_name};
            next unless keys $account_type->broker_codes->%*;

            for my $lc_name (keys $account_type->broker_codes->%*) {
                my $landing_company = LandingCompany::Registry->by_name($lc_name);

                ok $landing_company, "Valid landing company $lc_name in $category_name.$type_name broker code config";

                cmp_deeply(
                    $account_type->broker_codes->{$lc_name},
                    subsetof($landing_company->broker_codes->@*),
                    "$category_name.$type_name broker codes are found in landing company $lc_name"
                );
            }
        }
    }
};

subtest 'Method is_regulation_supported' => sub {
    my $p2p = BOM::Config::AccountType::Registry->account_type_by_name('p2p');

    is $p2p->is_regulation_supported('maltainvest'), 0, 'It should return false if account type doesnt support regulation';

    is $p2p->is_regulation_supported('svg'), 1, 'It should return false if account type supports regulation';
};

subtest 'Method is_supported for p2p' => sub {
    my $brand = Brands->new();

    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->mock(wallet_companies_for_country => ['svg']);

    my $p2p_config = BOM::Config::Runtime->instance->app_config->payments->p2p;

    my $p2p = BOM::Config::AccountType::Registry->account_type_by_name('p2p');

    $p2p_config->available(0);
    $p2p_config->restricted_countries([]);
    is $p2p->is_supported($brand, 'id', 'svg'), 0, 'It should return false if p2p is diabled';

    $p2p_config->available(1);
    $p2p_config->restricted_countries(['id']);
    is $p2p->is_supported($brand, 'id', 'svg'), 0, 'It should return false if contry is restricted';

    $p2p_config->restricted_countries([]);

    is $p2p->is_supported($brand, 'id', 'svg'), 1, 'It should return true p2p is available for the country';
};

subtest 'Method is_supported for mt5 and dxtrade' => sub {
    my $brand = Brands->new();

    my $mt5 = BOM::Config::AccountType::Registry->account_type_by_name('mt5');
    is $mt5->is_supported($brand, 'my', 'svg'), 0, 'It should return false if country doesnt support mt5';
    is $mt5->is_supported($brand, 'id', 'svg'), 1, 'It should return true if country supports mt5';

    my $dxtrade = BOM::Config::AccountType::Registry->account_type_by_name('dxtrade');
    is $dxtrade->is_supported($brand, 'es', 'svg'), 0, 'It should return false if country doesnt support dxtrade';
    is $dxtrade->is_supported($brand, 'id', 'svg'), 1, 'It should return true if country supports dxtrade';
};

subtest 'Method is_supported for standard' => sub {
    my $brand = Brands->new();

    my $standard = BOM::Config::AccountType::Registry->account_type_by_name('standard');
    is $standard->is_supported($brand, 'my', 'svg'), 0, 'it should return false for restricted country';
    is $standard->is_supported($brand, 'id', 'svg'), 1, 'it should return true for supported country';
};

subtest 'Method get_currencies' => sub {
    my $p2p = BOM::Config::AccountType::Registry->account_type_by_name('p2p');
    is_deeply $p2p->get_currencies('svg'), ['USD'], 'It should filter based currencies supported by account type';

    my $mt5 = BOM::Config::AccountType::Registry->account_type_by_name('mt5');
    is_deeply $mt5->get_currencies('svg'), ['AUD', 'EUR', 'GBP', 'USD'], 'It should filter based currencies type supported by account type';

    my @all_currencies = sort keys LandingCompany::Registry->by_name('svg')->legal_allowed_currencies->%*;

    my $crypto_config = Test::MockModule->new('BOM::Config::CurrencyConfig');

    my $standard = BOM::Config::AccountType::Registry->account_type_by_name('standard');

    $crypto_config->mock(is_crypto_currency_suspended => 0);
    is_deeply $standard->get_currencies('svg'), \@all_currencies, 'it should return all currencies if none of crypto currecies is suspended';

    $crypto_config->mock(is_crypto_currency_suspended => 1);
    is_deeply $standard->get_currencies('svg'), ['AUD', 'EUR', 'GBP', 'USD'],
        'it should return only fiat currencies if all of crypto currecies is suspended';

};

subtest 'Method get_details' => sub {
    my $brand = Brands->new();

    my $p2p = BOM::Config::AccountType::Registry->account_type_by_name('p2p');

    use Data::Dumper;

    is_deeply $p2p->get_details('svg'), {currencies => ['USD']}, 'It should return correct structure for wallet account';

    my $mt5 = BOM::Config::AccountType::Registry->account_type_by_name('mt5');

    cmp_deeply
        $mt5->get_details('svg'),
        {
        linkable_wallet_types          => bag('doughflow', 'paymentagent_client', 'p2p', 'virtual'),
        allowed_wallet_currencies      => ['AUD', 'EUR', 'GBP', 'USD'],
        linkable_to_different_currency => 1
        },
        'It should return correct structure for trading account';
};

subtest 'Method is_account_type_enabled' => sub {
    my $paymentagent = BOM::Config::AccountType::Registry->account_type_by_name('paymentagent');

    is $paymentagent->is_account_type_enabled, 0, 'It should return false because this account type is disabled';

    my $paymentagent_client = BOM::Config::AccountType::Registry->account_type_by_name('paymentagent_client');

    is $paymentagent_client->is_account_type_enabled, 0, 'It should return false because this account type is disabled';

    my $p2p = BOM::Config::AccountType::Registry->account_type_by_name('p2p');

    is $p2p->is_account_type_enabled, 0, 'It should return false because this account type is disabled';

    my $crypto = BOM::Config::AccountType::Registry->account_type_by_name('crypto');

    is $crypto->is_account_type_enabled, 1, 'It should return true if because this account type is enabled';

    my $doughflow = BOM::Config::AccountType::Registry->account_type_by_name('doughflow');

    is $doughflow->is_account_type_enabled, 1, 'It should return true if because this account type is enabled';
};

done_testing;
