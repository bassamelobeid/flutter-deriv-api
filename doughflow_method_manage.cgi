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

my $cgi    = CGI->new;
my %input  = %{request()->params};
my $broker = request()->broker_code;
my ($item, $success, $error, $check);

PrintContentType();
BrokerPresentation('DOUGHFLOW PAYMENT METHODS');

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'write'
    })->db->dbic;

if (my $id = $input{edit}) {
    try {
        $item = $db->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM payment.doughflow_method WHERE id = ?', undef, $id);
            });
        $error = 'Method does not exist' unless $item;
    } catch ($e) {
        $error = "Could not get method: $e";
    }
}

if (my $id = $input{delete_confirm}) {
    try {
        my ($result) = $db->run(
            fixup => sub {
                $_->selectrow_array(
                    "DELETE FROM payment.doughflow_method WHERE id = ?
                    RETURNING COALESCE(NULLIF(payment_processor,''), '[empty]') ||' - ' || COALESCE(NULLIF(payment_method,''), '[empty]')",
                    undef, $id
                );
            });
        $result ? ($success = $result . ' method has been deleted') : ($error = 'Method does not exist');
    } catch ($e) {
        $error = "Failed to delete method: $e";
    }
}

if ($input{update_confirm}) {
    try {
        validate(%input);
        my ($result) = $db->run(
            fixup => sub {
                $_->selectrow_array(
                    "UPDATE payment.doughflow_method SET payment_processor = ?, payment_method = ?, reversible = ?, deposit_poi_required = ?
                        WHERE id = ? AND NOT EXISTS (SELECT 1 FROM payment.doughflow_method WHERE payment_processor = ? AND payment_method = ? AND id <> ?)
                        RETURNING COALESCE(NULLIF(payment_processor,''), '[empty]') ||' - ' || COALESCE(NULLIF(payment_method,''), '[empty]')",
                    undef,
                    @input{
                        qw/payment_processor payment_method reversible deposit_poi_required update_confirm payment_processor payment_method update_confirm/
                    });
            });
        $result ? ($success = $result . ' method has been saved') : die "duplicate or does not exist\n";
    } catch ($e) {
        $error = "Failed to save method: $e";
    }
}

if ($input{create}) {
    try {
        validate(%input);
        my ($result) = $db->run(
            fixup => sub {
                $_->selectrow_array(
                    "INSERT INTO payment.doughflow_method (payment_processor, payment_method, reversible, deposit_poi_required) VALUES (?, ?, ?, ?)
                        ON CONFLICT(payment_processor, payment_method) DO NOTHING
                        RETURNING COALESCE(NULLIF(payment_processor,''), '[empty]') ||' - ' || COALESCE(NULLIF(payment_method,''), '[empty]')",
                    undef, @input{qw/payment_processor payment_method reversible deposit_poi_required/});
            });
        $result ? ($success = $result . ' method has been created') : die "duplicated method\n";
    } catch ($e) {
        $error = "Failed to create method: $e";
    }
}

if ($input{check}) {
    try {
        $check = $db->run(
            fixup => sub {
                $_->selectrow_hashref(
                    'SELECT SUM(net_amount) amount, COUNT(DISTINCT account_id) clients, MIN(aggregation_date) start_date, MAX(aggregation_date) end_date 
                        FROM payment.doughflow_totals_by_method WHERE payment_processor = ? and payment_method = ?',
                    undef, @input{qw/payment_processor payment_method/});
            });
        $check->@{qw/payment_processor payment_method/} = @input{qw/payment_processor payment_method/};
    } catch ($e) {
        $error = "Could not run transactions check: $e";
    }
}

my $methods = $db->run(
    fixup => sub {
        $_->selectall_arrayref('SELECT * FROM payment.doughflow_method ORDER BY payment_processor, payment_method', {Slice => {}});
    });

BOM::Backoffice::Request::template()->process(
    'backoffice/doughflow_method_manage.tt',
    {
        broker  => $broker,
        methods => $methods,
        item    => $item,
        delete  => $input{delete},
        success => $success,
        error   => $error,
        check   => $check,
    });

sub validate {
    my %input = @_;
    die "Cannot have empty processor and method\n" unless $input{payment_processor} or $input{payment_method};
    die "Cannot specify method if Deposit POI Required is enabled\n" if $input{deposit_poi_required} and $input{payment_method};
}

code_exit_BO();
