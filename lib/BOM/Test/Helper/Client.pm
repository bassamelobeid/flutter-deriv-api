package BOM::Test::Helper::Client;

use strict;
use warnings;

use Exporter qw( import );

use BOM::User::Client;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Password;
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Database::ClientDB;

our @EXPORT_OK = qw( create_client top_up close_all_open_contracts);

#
# wrapper for BOM::Test::Data::Utility::UnitTestDatabase::create_client(
#
sub create_client {
    my $broker   = shift || 'CR';
    my $skipauth = shift;
    my $args     = shift;
    my $client   = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => $broker,
            ($args ? %$args : ()),    # modification to default client info
        },
        $skipauth ? undef : 1
    );
    return $client;
}

sub top_up {
    my ($c, $cur, $amount, $payment_type) = @_;

    $payment_type //= 'ewallet';

    my $fdp = $c->is_first_deposit_pending;
    my $acc = $c->account($cur);

    # Define the transaction date here instead of use the now() as default in
    # postgres so we can mock the date.
    my $date = Date::Utility->new()->datetime_yyyymmdd_hhmmss;

    my ($pm) = $acc->add_payment({
        amount               => $amount,
        payment_gateway_code => "legacy_payment",
        payment_type_code    => $payment_type,
        status               => "OK",
        staff_loginid        => "test",
        remark               => __FILE__ . ':' . __LINE__,
        payment_time         => $date
    });
    $pm->legacy_payment({legacy_type => $payment_type});
    my ($trx) = $pm->add_transaction({
        account_id       => $acc->id,
        amount           => $amount,
        staff_loginid    => "test",
        remark           => __FILE__ . ':' . __LINE__,
        referrer_type    => "payment",
        action_type      => ($amount > 0 ? "deposit" : "withdrawal"),
        quantity         => 1,
        transaction_time => $date
    });
    $pm->save(cascade => 1);
    $trx->load;    # to re-read (get balance_after)

    BOM::Platform::Client::IDAuthentication->new(client => $c)->run_authentication
        if $fdp;

    note $c->loginid . "'s balance is now $cur " . $trx->balance_after . "\n";
    return;
}

1;
