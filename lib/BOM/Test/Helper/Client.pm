package BOM::Test::Helper::Client;

use strict;
use warnings;

use Exporter qw( import );

use Client::Account;
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Client::Utility;
use BOM::Platform::Password;
use Test::More;

our @EXPORT_OK = qw( create_client top_up );

sub create_client {
    my $broker   = shift || 'CR';
    my $skipauth = shift;
    my $client   = Client::Account->register_and_return_new_client({
        broker_code      => $broker,
        client_password  => BOM::Platform::Password::hashpw('12345678'),
        salutation       => 'Ms',
        last_name        => 'Doe',
        first_name       => 'Jane' . time . '.' . int(rand 1000000000),
        email            => 'jane.doe' . time . '.' . int(rand 1000000000) . '@test.domain.nowhere',
        residence        => 'in',
        address_line_1   => '298b md rd',
        address_line_2   => '',
        address_city     => 'Place',
        address_postcode => '65432',
        address_state    => 'st',
        phone            => '+9145257468',
        secret_question  => 'What the f***?',
        secret_answer    => BOM::Platform::Client::Utility::encrypt_secret_answer('is that'),
        date_of_birth    => '1945-08-06',
    });
    if (!$skipauth && $broker =~ /(?:MF|MLT|MX)/) {
        $client->set_status('age_verification');
        $client->set_authentication('ID_DOCUMENT')->status('pass') if $broker eq 'MF';
        $client->save;
    }
    return $client;
}

sub top_up {
    my ($c, $cur, $amount, $payment_type) = @_;

    $payment_type //= 'ewallet';

    my $fdp = $c->is_first_deposit_pending;
    my @acc = $c->account;

# two behaviours:
#_home_git_regentmarkets_bom-cryptocurrency_t_BOM_002_helper_b.t
#_home_git_regentmarkets_bom-platform_t_BOM_Platform_financial_market_bet_02.t
#_home_git_regentmarkets_bom-rpc_t_BOM_RPC_Transaction_12_copiers.t
#    return if (@acc && $acc[0]->currency_code ne $cur);
#
#    if (not @acc) {
#       @acc = $c->add_account({
#          currency_code => $cur,
#          is_default    => 1
#       });
#    }
#_home_git_regentmarkets_bom-transaction_t_BOM_transaction.t
#_home_git_regentmarkets_bom-transaction_t_BOM_transaction2.t
    if (@acc) {
        @acc = grep { $_->currency_code eq $cur } @acc;
        @acc = $c->add_account({
                currency_code => $cur,
                is_default    => 0
            }) unless @acc;
    } else {
        @acc = $c->add_account({
            currency_code => $cur,
            is_default    => 1
        });
    }

    my $acc = $acc[0];
    unless (defined $acc->id) {
        $acc->save;
        note 'Created account ' . $acc->id . ' for ' . $c->loginid . ' segment ' . $cur;
    }

    my ($pm) = $acc->add_payment({
        amount               => $amount,
        payment_gateway_code => "legacy_payment",
        payment_type_code    => $payment_type,
        status               => "OK",
        staff_loginid        => "test",
        remark               => __FILE__ . ':' . __LINE__,
    });
    $pm->legacy_payment({legacy_type => $payment_type});
    my ($trx) = $pm->add_transaction({
        account_id    => $acc->id,
        amount        => $amount,
        staff_loginid => "test",
        remark        => __FILE__ . ':' . __LINE__,
        referrer_type => "payment",
        action_type   => ($amount > 0 ? "deposit" : "withdrawal"),
        quantity      => 1,
    });
    $acc->save(cascade => 1);
    $trx->load;    # to re-read (get balance_after)

    BOM::Platform::Client::IDAuthentication->new(client => $c)->run_authentication
        if $fdp;

    note $c->loginid . "'s balance is now $cur " . $trx->balance_after . "\n";
    return;
}
1;
