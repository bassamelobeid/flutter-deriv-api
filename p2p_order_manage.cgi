#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use BOM::Database::ClientDB;
use Syntax::Keyword::Try;
use Date::Utility;
use BOM::Config::Runtime;

my $cgi = CGI->new;

PrintContentType();
BrokerPresentation(' ');

my $p2p_write = BOM::Backoffice::Auth0::has_authorisation(['P2PWrite']);

my %input  = %{request()->params};
my $broker = request()->broker_code;

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'write'
    })->db->dbic;

my ($order, $escrow, $transactions);

Bar('P2P Order details/management');

if (my $action = $input{action} and $p2p_write) {

    try {
        my ($status, $currency) = $db->run(
            fixup => sub {
                $_->selectrow_array('SELECT status, account_currency FROM p2p.order_list(?,NULL,NULL,NULL)', undef, $input{order_id});
            });

        die "Order is in $status status and cannot be resolved now.\n" unless $status eq 'timed-out';
        $escrow = get_escrow($broker, $currency);
        die "No escrow account is defined for $currency.\n" unless $escrow;

        my $txn_time = Date::Utility->new->datetime;
        my $staff    = BOM::Backoffice::Auth0::get_staffname();

        if ($action eq 'cancel') {
            $db->run(
                fixup => sub {
                    $_->do('SELECT p2p.order_cancel(?, ?, ?, ?, ?, ?)', undef, $input{order_id}, $escrow, 4, $staff, 'f', $txn_time);
                });
        }

        if ($action eq 'complete') {
            $db->run(
                fixup => sub {
                    $_->do('SELECT p2p.order_complete(?, ?, ?, ?, ?)', undef, $input{order_id}, $escrow, 4, $staff, $txn_time);
                });
        }
    }
    catch {
        my $error = ref $@ eq 'ARRAY' ? join ', ', $@->@* : $@;
        print '<p style="color:red; font-weight:bold;">' . $error . '</p>';
    }
}

if ($input{order_id}) {
    try {
        $order = $db->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM p2p.order_list(?,NULL,NULL,NULL)', undef, $input{order_id});
            });
        die "Order " . $input{order_id} . " not found\n" unless $order;
        if ($order->{type} eq 'buy') {
            $order->{client_role}     = 'BUYER';
            $order->{advertiser_role} = 'SELLER';
            $order->{buyer}           = $order->{client_loginid};
            $order->{seller}          = $order->{advertiser_loginid};
        } else {
            $order->{client_role}     = 'SELLER';
            $order->{advertiser_role} = 'BUYER';
            $order->{buyer}           = $order->{advertiser_loginid};
            $order->{seller}          = $order->{client_loginid};
        }
        $order->{client_id}   //= '[not an advertiser]';
        $order->{client_name} //= '[not an advertiser]';
        $order->{$_} = Date::Utility->new($order->{$_})->datetime_ddmmmyy_hhmmss for qw( created_time expire_time );
        ($order->{$_} = $order->{$_} ? 'Yes' : 'No') for qw( client_confirmed advertiser_confirmed );
        $order->{$_} = ucfirst($order->{$_}) for qw( type status );
        $order->{payment_due} = $order->{amount} * $order->{advert_rate};
        $escrow = get_escrow($broker, $order->{account_currency});

        $transactions = $db->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT pt.transaction_time, pt.type, 
                        tf.id src_id, af.client_loginid src_loginid, tf.amount src_amount, tf.staff_loginid src_staff, tf.action_type src_action_type, tf.payment_id src_payment_id,
                        tt.id dest_id, at.client_loginid dest_loginid, tt.amount dest_amount, tt.staff_loginid dest_staff, tt.action_type dest_action_type, tt.payment_id dest_payment_id
                    FROM p2p.p2p_transaction pt 
                        JOIN transaction.transaction tf ON tf.id = pt.from_transaction_id
                        JOIN transaction.account af ON af.id = tf.account_id 
                        JOIN transaction.transaction tt ON tt.id = pt.to_transaction_id
                        JOIN transaction.account at ON at.id = tt.account_id 
                        WHERE pt.order_id = ?
                        ORDER BY pt.transaction_time',
                    {Slice => {}}, $input{order_id});
            });
    }
    catch {
        print '<p style="color:red; font-weight:bold;">' . $@ . '</p>';
    }
}

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_order_manage.tt',
    {
        broker       => $broker,
        order        => $order,
        escrow       => $escrow,
        transactions => $transactions,
        p2p_write    => $p2p_write,
    });

code_exit_BO();

sub get_escrow {
    my ($broker, $currency) = @_;
    my @escrow_list = BOM::Config::Runtime->instance->app_config->payments->p2p->escrow->@*;
    foreach my $loginid (@escrow_list) {
        my $c = BOM::User::Client->new({loginid => $loginid});
        return $c->loginid if $c->broker eq $broker && $c->currency eq $currency;
    }
}
