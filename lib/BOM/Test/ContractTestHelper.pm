package BOM::Test::ContractTestHelper;

use strict;
use warnings;
use BOM::Config::RedisTransactionLimits;

use BOM::Test::FakeCurrencyConverter qw(fake_in_usd);
use BOM::Product::ContractFactory qw( produce_contract );
use LandingCompany::Registry;
use Exporter qw( import );

our @EXPORT_OK = qw(close_all_open_contracts reset_all_loss_hashes);

# As an alternative to deleting bets from unit test data, we can sell bets
# and set the sell_time to contract start date
sub close_all_open_contracts {
    my ($broker_code, $fullpayout) = @_;

    my $mocked_CurrencyConverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
    $mocked_CurrencyConverter->mock('in_usd', \&fake_in_usd);

    $broker_code //= 'CR';
    $fullpayout  //= 0;
    my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker_code});

    my $dbh = $clientdb->db->dbh;
    my $sql = q{select client_loginid,currency_code from transaction.account};
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my $output = $sth->fetchall_arrayref();

    foreach my $client_data (@$output) {
        foreach my $fmbo (
            @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client_data->[0], $client_data->[1], 'false']) // []})
        {
            my $contract = produce_contract($fmbo->{short_code}, $client_data->[1]);
            my $txn = BOM::Transaction->new({
                client   => BOM::User::Client->new({loginid => $client_data->[0]}),
                contract => $contract,
                source   => 23,
                price => ($fullpayout ? $fmbo->{payout_price} : $fmbo->{buy_price}),
                contract_id   => $fmbo->{id},
                purchase_date => $contract->date_start,
            });
            $txn->sell(skip_validation => 1);
        }
    }
    return;
}

sub reset_all_loss_hashes {
    my $redis;
    foreach my $landing_company (grep { $_->broker_codes->@* > 0 } LandingCompany::Registry::all()) {
        $redis = BOM::Config::RedisTransactionLimits::redis_limits_write($landing_company);
        my $lc = $landing_company->short;
        foreach my $loss_type (qw/turnover realized_loss potential_loss/) {
            $redis->del("$lc:$loss_type");
        }
    }

    return;
}

