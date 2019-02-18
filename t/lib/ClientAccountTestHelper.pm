package ClientAccountTestHelper;

use MooseX::Singleton;
use BOM::Database::ClientDB;
use BOM::User::Client;
use DBI;

use BOM::Test::Data::Utility::UnitTestDatabase;
use Date::Utility;

=head2 create_client({ broker_code => $broker_code})

    Use this to create a new client object for testing. broker_code is required.
    Additional args to the hashref can be specified which will update the
    relavant client attribute

=cut

sub create_client {
    my $args = shift;

    die "broker code required" if !exists $args->{broker_code};

    my $broker_code = delete $args->{broker_code};

    my $client_data = {
        loginid                  => undef,                                                                   ###
        client_password          => 'angelina',
        binary_user_id           => BOM::Test::Data::Utility::UnitTestDatabase::get_next_binary_user_id(),
        email                    => undef,                                                                   ####
        broker_code              => undef,                                                                   ####
        residence                => 'USA',
        citizen                  => 'USA',
        salutation               => 'MR',
        first_name               => 'bRaD',
        last_name                => 'pItT',
        address_line_1           => 'Civic Center',
        address_line_2           => '301',
        address_city             => 'Beverly Hills',
        address_state            => 'LA',
        address_postcode         => '232323',
        phone                    => '+112123121',
        latest_environment       => 'FireFox',
        secret_question          => 'How many child did I adopted',
        secret_answer            => 'its not your bussined',
        restricted_ip_address    => '',
        date_joined              => Date::Utility->new('20010108')->date_yyyymmdd,
        gender                   => 'm',
        cashier_setting_password => '',
        date_of_birth            => '1980-01-01',
    };
    $client_data->{email}       = 'unit_test' . rand . '@binary.com';
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

    my $client = BOM::User::Client->rnew;

    for (keys %$client_data) {
        $client->$_($client_data->{$_});
    }
    $client->save;

    return $client;
}

sub update_sequences {

    my $broker_code = shift || 'CR';
    my $connection_builder = BOM::Database::ClientDB->new({
        broker_code => $broker_code,
        operation   => 'write',
    });

    my $db  = $connection_builder->db;
    my $dbh = $db->dbh;

    _update_sequence_of({
        dbh      => $dbh,
        table    => 'transaction.account',
        sequence => 'account_serial',
    });

    _update_sequence_of({
        dbh      => $dbh,
        table    => 'transaction.transaction',
        sequence => 'transaction_serial',
    });

    _update_sequence_of({
        dbh      => $dbh,
        table    => 'payment.payment',
        sequence => 'payment_serial',
    });

    _update_sequence_of({
        dbh      => $dbh,
        table    => 'bet.financial_market_bet',
        sequence => 'bet_serial',
    });

    return undef;
}

sub _update_sequence_of {
    my $arg_ref = shift;

    my $table    = $arg_ref->{'table'};
    my $sequence = $arg_ref->{'sequence'};
    my $dbh      = $arg_ref->{'dbh'};

    my $statement;
    my $last_value;
    my $query_result;
    my $current_sequence_value = 0;

    $statement = qq{
        SELECT MAX(id) FROM $table;
    };
    $query_result = $dbh->selectrow_hashref($statement);
    $last_value = $query_result->{'max'} // $current_sequence_value;

    while ($current_sequence_value <= $last_value) {
        $statement = qq{
            SELECT nextval('sequences.$sequence'::regclass);
        };
        $query_result = $dbh->selectrow_hashref($statement);

        $current_sequence_value = $query_result->{'nextval'};
    }

    return $current_sequence_value;
}

1;
