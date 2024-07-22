use strict;
use warnings;
use utf8;

use BOM::Database::DataMapper::Transaction;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Customer;
use BOM::User::Password;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData               qw(create_underlying);
use BOM::Platform::Context        qw (localize);

use BOM::Transaction;
use BOM::Transaction::History qw(get_transaction_history);
use BOM::Transaction::Validation;
use BOM::Event::Actions::CustomerStatement;
use BOM::Test::Email;
use BOM::Test::Helper::P2P;

use Date::Utility;
use Data::Dumper;

use Test::MockModule;
use Test::More;
use Test::Warn;

use constant CONTRACT_START_DATE   => 1413892500;
use constant FOUR_HOURS_IN_SECONDS => 60 * 60 * 4;

my $service_contexts = BOM::Test::Customer::get_service_contexts();
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw(JPY USD JPY-USD);

my $now        = Date::Utility->new();
my $underlying = create_underlying('R_50');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => $now,
    });

my $old_tick1 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 99,
    underlying => 'R_50',
    quote      => 76.5996,
    bid        => 76.6010,
    ask        => 76.2030,
});

my $old_tick2 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 52,
    underlying => 'R_50',
    quote      => 76.6996,
    bid        => 76.7010,
    ask        => 76.3030,
});

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

my $test_customer = BOM::Test::Customer->create(
    residence => 'id',
    clients   => [{
            name        => 'CR',
            broker_code => 'CR',
        },
        {
            name            => 'CR_SIB',
            broker_code     => 'CR',
            default_account => 'LTC',
        },
    ]);

my $test_client  = $test_customer->get_client_object('CR');
my $test_sibling = $test_customer->get_client_object('CR_SIB');

$test_client->status->set('age_verification', 'test_name', 'test_reason');

my $req_args = {
    client    => $test_client,
    source    => 1,
    date_from => $now->epoch(),
    date_to   => $now->epoch(),
};

subtest 'Freshly created client - no account' => sub {
    # expected table cell values, expressed as regular expressions
    my $expected_content = {
        profile => [[
                $test_customer->get_first_name() . ' ' . $test_customer->get_last_name(),
                $test_client->loginid, 'No Currency Selected',
                'Retail',              '.+ to .+ \(inclusive\)'
            ],
        ],
        overview => [['', '', '', '', '', '', '']],
    };

    test_email_statement($test_customer, $req_args, $expected_content);
};

subtest 'Professional client - no transactions' => sub {
    $test_client->account('USD');
    $test_client->status->set("professional");

    my $expected_content = {
        profile => [[
                $test_customer->get_first_name() . ' ' . $test_customer->get_last_name(),
                $test_client->loginid, 'USD', 'Professional', '.+ to .+ \(inclusive\)'
            ],
        ],
        overview => [['^0\.00$', '^0\.00$', '^0\.00$', '^0\.00$', '^0\.00$', '0\.00$', '^0\.00$']],
    };

    test_email_statement($test_customer, $req_args, $expected_content);
};

subtest 'client with payments, trades and P2P' => sub {

# deposit, amount will be used as a key for matching later
    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 50000,
        remark   => 'free gift',
    );

    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 100,
        remark   => 'free gift',
    );

# withdraw, amount will be used as a key for matching later
    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => -1032,
        remark   => 'not so free gift',
    );

    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => -1032,
        remark   => 'second not so free gift',
    );

# buy some close trade

# epoch of Tuesday, 21 October 2014 11:55:00
# this is to make sure that date is consistent so that it can be tested
# later in the email payload
    my $R_100_start = Date::Utility->new(CONTRACT_START_DATE);

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => 'USD',
            recorded_date => $R_100_start,
        });

# create some ticks for the contract
    my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $R_100_start->epoch,
        quote      => 100
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $R_100_start->epoch + 30,
        quote      => 111
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $R_100_start->epoch + FOUR_HOURS_IN_SECONDS,
        quote      => 80
    });

    my $contract_expired = {
        underlying   => create_underlying('R_100'),
        bet_type     => 'CALL',
        currency     => 'USD',
        stake        => 100,
        date_start   => $R_100_start->epoch,
        date_pricing => $R_100_start->epoch,
        date_expiry  => CONTRACT_START_DATE + FOUR_HOURS_IN_SECONDS,    # set expiry date to 4 hours later
        current_tick => $entry_tick,
        entry_tick   => $entry_tick,
        barrier      => 'S0P',
    };

    my $txn = BOM::Transaction->new({
            client              => $test_client,
            contract_parameters => $contract_expired,
            price               => 100,
            payout              => 200,
            amount_type         => 'stake',
            purchase_date       => $R_100_start->epoch - 101,

    });

    my $error = $txn->buy(skip_validation => 1);
    is $error, undef, 'no error buying contract';

# sell expired contract
    BOM::Transaction::sell_expired_contracts({
        client => $test_client,
        source => 1,
    });

# buy some open trades at different interval so we can test our folder
    my $contract = produce_contract({
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 1000,
        duration     => '10h',
        current_tick => $tick,
        entry_tick   => $tick,
        exit_tick    => $tick,
        barrier      => 'S0P',
    });

    $txn = BOM::Transaction->new({
        client        => $test_client,
        contract      => $contract,
        price         => 514.00,
        payout        => $contract->payout,
        amount_type   => 'payout',
        source        => 19,
        purchase_date => $contract->date_start,
    });
    $error = $txn->buy(skip_validation => 1);
    is $error, undef, 'no error buying contract';

# perform transfer between accounts
    $txn = $test_client->payment_account_transfer(
        currency    => 'USD',
        amount      => 10,
        to_amount   => 1,
        toClient    => $test_sibling,
        remark      => 'blabla',
        fees        => 1.1,
        txn_details => {
            from_login                => $test_client->loginid,
            to_login                  => $test_sibling->loginid,
            fees                      => 1.1,
            fees_currency             => 'USD',
            fees_percent              => 1.5,
            min_fee                   => 0.5,
            fee_calculated_by_percent => 1.1,
        },
    );

# perform 2 p2p escrow transactions
    BOM::Test::Helper::P2P::bypass_sendbird();
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'buy');
    $test_client->p2p_advertiser_create(name => 'test client');
    my $order = BOM::Test::Helper::P2P::create_order(
        amount    => 50,
        advert_id => $advert->{id},
        client    => $test_client,
    );
    $advertiser->p2p_order_cancel(id => $order->{id});

    $req_args = {
        client    => $test_client,
        source    => 1,
        date_from => $R_100_start->epoch(),
        date_to   => $now->epoch() + 100,     # adding off set for buy contract
    };

    my $date_format = $now->date_yyyymmdd . ' \d{2}:\d{2}:\d{2}';

    my $expected_content = {
        profile => [[
                $test_customer->get_first_name() . ' ' . $test_customer->get_last_name(),
                $test_client->loginid, 'USD', 'Professional', '.+ to .+ \(inclusive\)'
            ],
        ],
        overview     => [['^0\.00$', '^50100\.00$', '^\-2074.00', '^\-614\.00$', '^0\.00$', '47412\.00$', '^47886.00$']],
        close_trades => [[
                $date_format, '\d+',
                '^sell$',     'Win payout if Volatility 100 Index is strictly higher than entry spot at 4 hours after contract start time.',
                '^100\.00$',  '^0\.00$', '^200\.00$', '^0\.00$'
            ],
            [
                '2014-10-21 \d{2}:\d{2}:\d{2}',
                '\d+', '^buy$', 'Win payout if Volatility 100 Index is strictly higher than entry spot at 4 hours after contract start time.',
                '^100.00$', '^0.00$', '^200.00$', '^-100.00$'
            ],
        ],
        open_trades => [[
                $date_format, '\d+', 'Win payout if Volatility 50 Index is strictly higher than entry spot at 10 hours after contract start time.',
                '^514.00$',   '^1000.00$', '\d+\.\d+',
                '\d+\-\w+\-\d+\s\d{2}:\d{2}:\d{2}',
                '\d+\-\w+\-\d+\s\d{2}:\d{2}:\d{2}',
                '[10|9] Hours'
            ],
        ],
        payments => [
            [$date_format, '\d+', '^$',         '^\-10\.00$',   '^internal transfer$'],
            [$date_format, '\d+', '^$',         '^\-1032\.00$', '^withdrawal$'],
            [$date_format, '\d+', '^$',         '^\-1032\.00$', '^withdrawal$'],
            [$date_format, '\d+', '^100.00$',   '^$',           '^deposit$'],
            [$date_format, '\d+', '^50000.00$', '^$',           '^deposit$'],

        ],
        escrow => [
            [$date_format, '\d+', 'release', '^50\.00$',   'P2P order \d+ cancelled'],
            [$date_format, '\d+', '^hold$',  '^\-50\.00$', 'P2P order \d+ created']
        ],
    };

    test_email_statement($test_customer, $req_args, $expected_content);

    subtest 'Offerings unavailable' => sub {
        my $mock_lc = Test::MockModule->new('LandingCompany');
        $mock_lc->mock('default_product_type' => sub { return undef });

        $expected_content->{overview} = [['^0\.00$', '^50100\.00$', '^\-2074.00', '47412\.00$']];

        test_email_statement($test_customer, $req_args, $expected_content);

        $mock_lc->unmock_all;
    };
};

subtest 'payment agent' => sub {
    my $pa_customer = BOM::Test::Customer->create(clients => [{name => 'CR', broker_code => 'CR', default_account => 'USD'}]);
    my $pa_client   = $pa_customer->get_client_object('CR');

    $pa_client->payment_agent({
        payment_agent_name    => 'Joe',
        email                 => 'joe@example.com',
        information           => 'Test Info',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        currency_code         => 'USD',
        is_listed             => 't',
    });
    $pa_client->save;
    $pa_client->get_payment_agent->set_countries(['id']);

    my $pa_customer2 = BOM::Test::Customer->create(
        residence => 'id',
        clients   => [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'USD',
            },
        ]);
    my $client = $pa_customer2->get_client_object('CR');

    $pa_client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );

    $pa_client->payment_account_transfer(
        toClient           => $client,
        currency           => 'USD',
        amount             => 100,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
    );

    $client->payment_account_transfer(
        toClient     => $pa_client,
        currency     => 'USD',
        amount       => 99,
        fees         => 0,
        gateway_code => 'payment_agent_transfer',
    );

    my $req_args = {
        client    => $pa_client,
        source    => 1,
        date_from => $now->epoch() - 100,
        date_to   => $now->epoch() + 100,
    };

    my $expected_content = {
        profile =>
            [[$pa_customer->get_first_name() . ' ' . $pa_customer->get_last_name(), $pa_client->loginid, 'USD', 'Retail', '.+ to .+ \(inclusive\)'],],
        overview      => [['^0\.00$', '^1099\.00$', '^-100.00', '^0\.00$', '^0\.00$', '999\.00$', '^999.00$']],
        payments      => [['\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}', '\d+', '^1000.00$', '^$', '^deposit$'],],
        payment_agent => [
            ['\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}', '\d+', 'Transfer in',  '^99.00$',   'Transfer from ' . $client->loginid],
            ['\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}', '\d+', 'Transfer out', '^-100.00$', 'Transfer to ' . $client->loginid],
        ],
    };

    test_email_statement($pa_customer, $req_args, $expected_content);

};

sub test_email_statement {
    my ($customer, $args, $expected) = @_;

    mailbox_clear();
    my $status = BOM::Event::Actions::CustomerStatement::_send_email_statement($args, $service_contexts);

    is $status->{status_code}, 1, 'email has been sent';

    my @msgs = mailbox_search(
        email   => $customer->get_email(),
        subject => qr/Statement from .+ to .+/
    );

    ok @msgs == 1, 'only one email has been sent';

    my @table_names = ('profile', 'overview', 'close_trades', 'open_trades', 'payments', 'escrow', 'payment_agent');

    my $body           = $msgs[0]->{body};
    my @matched_tables = $body =~ /<tbody>[<>="\/.*&;:\-\s\w()]*?<\/tbody>/g;

    is scalar @matched_tables, scalar keys %$expected, 'Number of tables in email body is correct: ' . scalar keys %$expected;

    my $tables = {};
    my $idx    = 0;
    for my $table_name (@table_names) {
        next unless $expected->{$table_name};
        # push all the header and content of table into the array
        my (@table_headers, @table_data);

        push @table_headers, $2 while ($matched_tables[$idx] =~ /(<th scope="col">|<th[\s\w="]*>)([\w\s:&;*\/]*)(<[\/]*th>)/g);
        push @table_data,    $2 while ($matched_tables[$idx] =~ /(<td[\s\w="\-:]*>)([\w\s:&;*\/\.\-\(\)]*)(<[\/=\s]*td>)/g);

        my $expected_data = $expected->{$table_name};
        $tables->{$table_name} = {
            table_headers    => \@table_headers,
            table_data       => \@table_data,
            expected_data    => $expected_data,
            expected_columns => scalar(@{$expected_data->[0] // []}),
        };
        $idx++;
    }

    # table hears
    for my $table (keys %$tables) {
        my $expected_count = scalar $tables->{$table}->{expected_columns};
        my $observed_count = scalar $tables->{$table}->{table_headers}->@*;
        is $observed_count, $expected_count, "$table column count is $expected_count as expected";
    }

    # table data
    for my $table (keys %$tables) {
        my @expected_cells = map { @$_ } $tables->{$table}->{expected_data}->@*;
        my @observed_cells = $tables->{$table}->{table_data}->@*;

        is scalar @observed_cells, scalar @expected_cells, "$table cell count is correct: " . scalar @expected_cells;

        for my $idx (0 .. @expected_cells - 1) {
            my $value = $observed_cells[$idx] =~ s/^\s+|\s+$//rg;    # trim
            like $value, qr/$expected_cells[$idx]/, "$table cell $idx content is correct";
        }
    }
}

done_testing();
1;
