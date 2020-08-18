package BOM::Test::Contract;

=head1 NAME

BOM::Test::Contract

=head1 DESCRIPTION

To be used by an RMG unit test.

Focuses only on testing buying and selling contracts; encapsulates all
the boilerplate code away from developer. All contract validations are skipped
and assumed to pass so that we can set our own buy price and sell result.

=cut

use 5.010;
use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Warnings;
use Test::Exception;
use Guard;
use Crypt::NamedKeys;
use Finance::Contract::Longcode qw( shortcode_to_parameters );
use BOM::User::Client;
use BOM::User::Password;
use BOM::Config::Runtime;

use Date::Utility;
use BOM::Transaction;
use BOM::Transaction::Validation;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw( produce_contract  make_similar_contract);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Time qw( sleep_till_next_second );
use BOM::Platform::Client::IDAuthentication;
use Data::Dumper;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Exporter qw( import );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

our @EXPORT_OK = qw(
    create_contract
    buy_contract
    sell_contract
    batch_buy_contract
    sell_by_shortcode
    close_all_open_contracts
);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(validate_tnc          => sub { });
$mock_validation->mock(compliance_checks     => sub { });
$mock_validation->mock(check_tax_information => sub { });

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for qw(JPY USD JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });

# Spread is calculated base on spot of the underlying.
# In this case, we mocked the spot to 100.
my $mocked_underlying = Test::MockModule->new('Quant::Framework::Underlying');
$mocked_underlying->mock('spot', sub { 100 });

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub get_transaction_from_db {
    my $bet_class = shift;
    my $txnid     = shift;

    my $stmt = <<"SQL";
SELECT t.*, b.*, c.*, v1.*, v2.*, t2.*
  FROM transaction.transaction t
  LEFT JOIN bet.financial_market_bet b ON t.financial_market_bet_id=b.id
  LEFT JOIN bet.${bet_class} c ON b.id=c.financial_market_bet_id
  LEFT JOIN data_collection.quants_bet_variables v1 ON t.id=v1.transaction_id
  LEFT JOIN data_collection.quants_bet_variables v2 ON b.id=v2.financial_market_bet_id AND v2.transaction_id<>t.id
  LEFT JOIN transaction.transaction t2 ON t2.financial_market_bet_id=t.financial_market_bet_id AND t2.id<>t.id
 WHERE t.id=\$1
SQL

    my $db = db;
    $stmt = $db->dbh->prepare($stmt);
    $stmt->execute($txnid);

    my $res = $stmt->fetchrow_arrayref;
    $stmt->finish;

    my @txn_col  = BOM::Database::AutoGenerated::Rose::Transaction->meta->columns;
    my @fmb_col  = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->columns;
    my @chld_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->{relationships}->{$bet_class}->class->meta->columns;
    my @qv_col   = BOM::Database::AutoGenerated::Rose::QuantsBetVariable->meta->columns;

    BAIL_OUT "DB structure does not match Rose classes"
        unless 2 * @txn_col + @fmb_col + @chld_col + 2 * @qv_col == @$res;

    my $contract_info;

    my %txn;
    @txn{@txn_col} = splice @$res, 0, 0 + @txn_col;
    $contract_info->{txn} = \%txn;

    my %fmb;
    @fmb{@fmb_col} = splice @$res, 0, 0 + @fmb_col;
    $contract_info->{fmb} = \%fmb;

    my %chld;
    @chld{@chld_col} = splice @$res, 0, 0 + @chld_col;
    $contract_info->{chld} = \%chld;

    my %qv1;
    @qv1{@qv_col} = splice @$res, 0, 0 + @qv_col;
    $contract_info->{qv1} = \%qv1;

    my %qv2;
    @qv2{@qv_col} = splice @$res, 0, 0 + @qv_col;
    $contract_info->{qv2} = \%qv2;

    my %t2;
    @t2{@txn_col} = splice @$res, 0, 0 + @txn_col;
    $contract_info->{t2} = \%t2;

    return $contract_info;
}

sub get_tick {
    my %params = @_;
    state $ticks_hash;
    my $epoch = $now->epoch;
    my $key   = "$params{underlying}$epoch";
    my $cache = $ticks_hash->{$key};

    return $cache if $cache;

    return $ticks_hash->{$key} //= do {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $epoch,
            underlying => $params{underlying},
        });
    }
}

sub get_underlying {
    my ($underlying) = @_;
    state $underlyings_hash;

    my $cache = $underlyings_hash->{$underlying};

    return $cache if $cache;

    my $new_underlying = create_underlying($underlying);
    $underlyings_hash->{$underlying} = $new_underlying;

    return $new_underlying;
}

sub create_contract {
    my (%params) = @_;

    my $underlying = delete $params{underlying};
    my $tick       = get_tick(
        underlying => $underlying,
    );

    $params{date_start} = delete $params{purchase_date} || Date::Utility->new();

    my %contract_params = (
        currency     => 'USD',
        underlying   => get_underlying($underlying),
        current_tick => $tick,
        %params,
    );

    return produce_contract(\%contract_params);
}

sub buy_contract {
    my (%params) = @_;

    my $contract = $params{contract};

    my %transaction_params = (
        client        => $params{client},
        contract      => $contract,
        price         => $params{buy_price},
        source        => 19,
        purchase_date => $contract->date_start,
    );

    # I'm not sure if there's a better way to do this...
    my $build_parameters = $contract->build_parameters;
    if (exists $build_parameters->{payout}) {
        $transaction_params{amount_type} = 'payout';
    } elsif (exists $build_parameters->{multiplier}) {
        $transaction_params{amount_type} = 'multiplier';
    } elsif (exists $build_parameters->{stake}) {
        $transaction_params{amount_type} = 'stake';
    } else {
        die 'I do not know the amount type to this contract';
    }

    my $txn = BOM::Transaction->new(\%transaction_params);

    my $error = $txn->buy(skip_validation => 1);

    my $buy_ref;
    $buy_ref = get_transaction_from_db(higher_lower_bet => $txn->transaction_id) unless $error;

    return $error, $buy_ref;
}

sub batch_buy_contract {
    my (%params) = @_;

    my $contract = $params{contract};
    my @multiple = map { {loginid => $_->loginid} } @{$params{clients}};

    my $txn = BOM::Transaction->new({
        client        => $params{manager_client},
        contract      => $contract,
        price         => $params{buy_price},
        payout        => $contract->payout,
        amount_type   => 'payout',
        multiple      => \@multiple,
        purchase_date => $contract->date_start,
    });

    my $error = $txn->batch_buy(skip_validation => 1);

    return ($error, $txn->multiple);
}

sub sell_by_shortcode {
    my (%params) = @_;

    # Unlike batch_buy, buy and sell, sell_by_shortcode does not have a param to skip_validation,
    # so we need to mock the validations away.
    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock(is_valid_to_sell => sub { note "mocked Contract->is_valid_to_sell returning true"; 1 });
    my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
    $mock_validation->mock(
        _validate_sell_pricing_adjustment => sub { note "mocked Transaction::Validation->_validate_sell_pricing_adjustment returning nothing"; () });
    $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

    my $manager_client = $params{manager_client};

    my $contract_parameters = shortcode_to_parameters($params{shortcode}, $manager_client->currency);
    $contract_parameters->{landing_company} = $manager_client->landing_company->short;
    my $contract = produce_contract($contract_parameters);

    my $new_c = make_similar_contract($contract, {date_pricing => ($params{sell_time} ? $params{sell_time} : $contract->date_start->epoch + 1)});

    my @multiple = map { {loginid => $_->loginid} } @{$params{clients}};

    my $txn = BOM::Transaction->new({
        client   => $manager_client,
        contract => $new_c,
        # sell_outcome is a value from from 0 to 1;
        # 0 for loss, 1 for win, and anything in between is
        # a premature sell
        price         => $new_c->payout * $params{sell_outcome},
        multiple      => \@multiple,
        purchase_date => $new_c->date_start,
        source        => 1,
    });
    my $error = $txn->sell_by_shortcode();

    return ($error, $txn->multiple);
}

sub sell_contract {
    my (%params) = @_;
    my $contract = $params{contract};
    my $new_c    = make_similar_contract($contract, {date_pricing => ($params{sell_time} ? $params{sell_time} : $contract->date_start->epoch + 1)});

    my $txn = BOM::Transaction->new({
        purchase_date => $new_c->date_start,
        client        => $params{client},
        contract      => $new_c,
        contract_id   => $params{contract_id},
        amount_type   => 'payout',
        # sell_outcome is a value from from 0 to 1;
        # 0 for loss, 1 for win, and anything in between is
        # a premature sell
        # TODO: currently this class is under the assumption that every contract
        #       has a payout. This is not always the case and for such contracts the
        #       sell is always a fail regardless of what sell_outcome is set
        price  => $new_c->payout * $params{sell_outcome},
        source => 23,
    });

    my $error = $txn->sell(skip_validation => 1);

    return $error if $error;

    return;
}

1;
