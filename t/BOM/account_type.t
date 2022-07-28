use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::MockModule;

use BOM::Config::AccountType::Registry;

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
            is(BOM::Config::AccountType::Registry->account_type_by_name($category_name, $type_name),
                $account_type, "Account type $category_name-$type_name is found in registry");

            my $type_config = $category_config->{account_types}->{$type_name};

            cmp_deeply [map { $_->name } $account_type->groups->@*], bag($type_config->{groups}->@*, $category_config->{groups}->@*),
                "Account type $category_name-$type_name 's groups are correctly loaded";
            is_deeply $account_type->broker_codes, $type_config->{broker_codes} // $category->broker_codes,
                "Account type $category_name-$type_name 's broker codes are correct";

            $groups_used{$_} = 1 for $type_config->{groups}->@*;
        }
    }

    cmp_deeply [keys $config->{groups}->%*], bag(keys %groups_used), 'All groups are used in account types and categories';
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
    is_deeply $category->broker_codes, {svg => ['CRW']}, 'broker codes are correct';
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

    is $account_type->name,                           'my_type', 'Name is correct';
    is $account_type->category_name,                  'wallet',  'Category name is correct';
    is $account_type->category,                       BOM::Config::AccountType::Registry->category_by_name('wallet'), 'Category object is correct';
    is $account_type->is_demo,                        0, 'account type is not demo';
    is $account_type->linkable_to_different_currency, 0, 'it is not linkable to a different currency';

    is_deeply $account_type->brands,   ['deriv'], 'Brands are the same as the category';
    is_deeply $account_type->groups,   [], 'Groups are empty';
    is_deeply $account_type->services, [], 'Services are empty (no group)';
    is_deeply $account_type->broker_codes,
        {
        svg         => ['CRW'],
        maltainvest => ['MFW']
        },
        'Broker codes are the same as the category';
    is_deeply $account_type->linkable_wallet_types, [], 'No linkable wallet types';
    is_deeply $account_type->currencies,            [], 'No limited currency';
    is_deeply $account_type->currency_types,        [], 'Currency type is not limited';
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
    $args{is_demo}               = 1;
    like exception { BOM::Config::AccountType->new(%args) },
        qr/Demo account type wallet-my_type is linked to non-demo wallet all/, 'Demo account type can be linked to demo wallet only';

    $args{is_demo}    = 0;
    $args{currencies} = ['XYZ'];
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
        'Correct error for invalid landing company';

    $args{currencies_by_landing_company}  = {svg => ['BTC']};
    $args{is_demo}                        = 1;
    $args{linkable_wallet_types}          = ['demo'];
    $args{linkable_to_different_currency} = 1;
    ok $account_type = BOM::Config::AccountType->new(%args), 'Account type created with full args';

    my %expected = (%args, services => ['link_to_accounts']);
    is_deeply($account_type->$_, $expected{$_}, "Value of $_ is correct") for keys %expected;
};

done_testing;
