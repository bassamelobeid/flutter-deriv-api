package BOM::Test::Data::Utility::UnitTestDatabase;

use MooseX::Singleton;
use BOM::Database::ClientDB;
use BOM::Platform::Client;
use BOM::Database::Model::FinancialMarketBet::HigherLowerBet;
use BOM::Database::Model::FinancialMarketBet::SpreadBet;
use BOM::Database::Model::FinancialMarketBet::TouchBet;
use BOM::Database::Model::FinancialMarketBet::RangeBet;
use BOM::Database::Helper::FinancialMarketBet;

use Date::Utility;

sub _db_name {
    return 'regentmarkets';
}

sub _db_migrations_dir {
    return 'rmgdb';
}

sub _build__connection_parameters {
    my $self = shift;
    return {
        database => 'regentmarkets',
        domain   => 'TEST',
        driver   => 'Pg',
        host     => 'localhost',
        port     => '5432',
        user     => 'postgres',
        password => 'mRX1E3Mi00oS8LG',
    };
}

sub _post_import_operations {
    my $self = shift;

    $self->_update_sequence_of({
        table    => 'transaction.account',
        sequence => 'account_serial',
    });

    $self->_update_sequence_of({
        table    => 'transaction.transaction',
        sequence => 'transaction_serial',
    });

    $self->_update_sequence_of({
        table    => 'payment.payment',
        sequence => 'payment_serial',
    });

    $self->_update_sequence_of({
        table    => 'bet.financial_market_bet',
        sequence => 'bet_serial',
    });

    return;
}

=head2 create_client({ broker_code => $broker_code})

    Use this to create a new client object for testing. broker_code is required.
    Additional args to the hashref can be specified which will update the
    relavant client attribute

=cut

sub create_client {
    my $args = shift;

    die "broker code required" if !exists $args->{broker_code};

    my $broker_code = delete $args->{broker_code};

    my $fixture     = YAML::XS::LoadFile('/home/git/regentmarkets/bom-test/data/couch_unit_test.yml');
    my $client_data = $fixture->{client}{data};
    $client_data->{email}       = 'unit_test@binary.com';
    $client_data->{broker_code} = $broker_code;

    # get next seq for loginid
    my $connection_builder = BOM::Database::ClientDB->new({
        broker_code => $broker_code,
        operation   => 'write',
    });

    my $db  = $connection_builder->db;
    my $dbh = $db->dbh;

    my $sequence_name        = 'sequences.loginid_sequence_' . $broker_code;
    my $loginid_sequence_sql = "SELECT nextval('$sequence_name')";
    my $loginid_sequence_sth = $dbh->prepare($loginid_sequence_sql);
    $loginid_sequence_sth->execute();
    my @loginid_sequence = $loginid_sequence_sth->fetchrow_array();
    my $new_loginid      = $broker_code . $loginid_sequence[0];

    $client_data->{loginid} = $new_loginid;

    # any modify args were specified?
    for (keys %$args) {
        $client_data->{$_} = $args->{$_};
    }

    my $client = BOM::Platform::Client->rnew;

    for (keys %$client_data) {
        $client->$_($client_data->{$_});
    }
    $client->save;

    return $client;
}

=head2 create_fmb()

    Create a new FinancialMarketBet (fmb) object

=cut

sub create_fmb {
    my $args = shift;

    my $fixture   = YAML::XS::LoadFile('/home/git/regentmarkets/bom-test/data/couch_unit_test.yml');
    my $type      = delete $args->{type};
    my $fmb_data  = $fixture->{$type}{data};
    my $fmb_class = $fixture->{$type}{class_name};

    # execute buy_bet by default. Sometimes only a FMB object
    # needs to be created.
    my $buy_bet = 1;
    if (exists $args->{buy_bet}) {
        $buy_bet = delete $args->{buy_bet};
    }

    # any modify args were specified?
    for (keys %$args) {
        $fmb_data->{$_} = $args->{$_};
    }

    my $must_sell = delete $fmb_data->{__MUST_SELL__};
    my $sell_time = delete $fmb_data->{__SELL_TIME__};
    my $sell_price;

    # check constraint in fmb check for:
    #   is_sold = 0, sell_price = NULL
    #   is_sold = 1, sell_price != NULL
    if (not defined $fmb_data->{is_sold} or $fmb_data->{is_sold} == 0) {
        $sell_price = delete $fmb_data->{sell_price};
    }

    my $client_loginid;
    my $account_id;
    my $currency_code;

    my $connection_builder = BOM::Database::ClientDB->new({
        broker_code => 'CR',
        operation   => 'write',
    });

    if ($fmb_data->{'account_id'} eq '__DUMMY__') {

        # create client with account
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        my $account = $client->set_default_account('USD');
        $fmb_data->{'account_id'} = $account->id;
        $account_id = $account->id;

        if (exists $fmb_data->{__CREDIT_AMOUNT__}) {
            $client->payment_free_gift(
                currency => 'USD',
                amount   => $fmb_data->{__CREDIT_AMOUNT__},
                remark   => 'free gift',
            );

            delete $fmb_data->{__CREDIT_AMOUNT__};
        }

        $client_loginid = $client->loginid;
        $currency_code  = $account->currency_code;
    } else {

        # make sure account_id exists
        die "account_id required" if !exists $fmb_data->{account_id};

        my $acc_id = $fmb_data->{account_id};
        my $acc    = BOM::Database::AutoGenerated::Rose::Account->new(
            id => $acc_id,
            db => $connection_builder->db,
        );
        $acc->load;

        $client_loginid = $acc->client_loginid;
        $account_id     = $acc_id;
        $currency_code  = $acc->currency_code;
    }

    $fmb_data->{short_code} = 'DUMMYSHORTCODE_' . rand(99999)
        unless defined $fmb_data->{short_code};

    my $fmb = $fmb_class->new({
        data_object_params => $fmb_data,
        db                 => $connection_builder->db,
    });
    $fmb->save;

    if (!$buy_bet) {
        return $fmb;
    }

    my $rec  = $fmb->financial_market_bet_record;
    my @cols = $rec->meta->columns;

    my %bet = map {
        my $v = $rec->$_;    # some of the values are objects (DateTime) with overloaded "".
        defined($v) ? ($_ => "$v") : ();    # Need to stringify but also keep undefined values.
    } @cols;

    $rec  = $fmb->${\"$bet{bet_class}_record"};
    @cols = $rec->meta->columns;

    %bet = (
        %bet,
        map {
            my $v = $rec->$_;
            defined($v) ? ($_ => "$v") : ();
        } @cols
    );
    delete @bet{qw/sell_price sell_time is_sold/};    # not allowed during buy

    my %trans = (transaction_time => $fmb_data->{transaction_time});

    my $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $client_loginid,
                currency_code  => $currency_code,
            },
            bet_data         => \%bet,
            transaction_data => \%trans,
            db               => $connection_builder->db,
        });
    my ($fmb_rec, $trx_rec) = $fmb_helper->buy_bet;
    $fmb->financial_market_bet_record(ref($fmb->financial_market_bet_record)->new(%$fmb_rec));
    $fmb->financial_market_bet_id($fmb_rec->{id});

    if ($must_sell) {
        $bet{id}                 = $fmb_rec->{id};
        $bet{sell_price}         = $sell_price;
        $bet{sell_time}          = Date::Utility->new->db_timestamp;
        $bet{is_sold}            = 1;
        $trans{transaction_time} = $sell_time;

        ($fmb_rec, $trx_rec) = $fmb_helper->sell_bet;
    }

    return $fmb;
}

sub create_valid_contract {
    my $args = shift;

    my $is_expired = $args->{is_expired};
    my $start_time = $args->{start_time};

    my $start = Date::Utility->new($start_time);
    $start = $start->minus_time_interval('1h 2m') if $is_expired;
    my $expire = $start->plus_time_interval('2m');

    for my $epoch ($start->epoch, $start->epoch + 1, $expire->epoch) {
        my $api = BOM::Market::Data::DatabaseAPI->new(underlying => 'R_100');
        my $tick = $api->tick_at({end_time => $epoch});
        next if $tick;

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $epoch,
            underlying => $args->{underlying} || 'R_100',
        });
    }

    my $short_code;
    if ($args->{short_code_prefix} && $args->{short_code_postfix}) {
        $short_code = join('_', $args->{short_code_prefix}, $start->epoch(), $expire->epoch(), $args->{short_code_postfix});
    }

    $args->{short_code} = $short_code if $short_code;

    my $bet = create_fmb({
        purchase_time    => $start->datetime_yyyymmdd_hhmmss,
        transaction_time => $start->datetime_yyyymmdd_hhmmss,
        start_time       => $start->datetime_yyyymmdd_hhmmss,
        expiry_time      => $expire->datetime_yyyymmdd_hhmmss,
        settlement_time  => $expire->datetime_yyyymmdd_hhmmss,
        %$args,
    });

    return $bet;
}

with 'BOM::Test::Data::Utility::TestDatabaseSetup';

no Moose;
__PACKAGE__->meta->make_immutable;

## no critic (Variables::RequireLocalizedPunctuationVars)
sub import {
    my ($class, $init) = @_;

    if ($init && $init eq ':init') {

        __PACKAGE__->instance->prepare_unit_test_database;

        require BOM::Test::Data::Utility::UserTestDatabase;
        BOM::Test::Data::Utility::UserTestDatabase->import(':init');
    }
    return;
}

1;
