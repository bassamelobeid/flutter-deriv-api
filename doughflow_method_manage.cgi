#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
BOM::Backoffice::Sysinit::init();

use BOM::Database::ClientDB;
use BOM::Config::Runtime;
use Syntax::Keyword::Try;
use List::Util qw(max);

my $cgi    = CGI->new;
my %input  = %{request()->params};
my $broker = request()->broker_code;
my ($item, $success, $error, $check);

PrintContentType();
BrokerPresentation('DOUGHFLOW PAYMENT METHODS');

my $reversible_days = BOM::Config::Runtime->instance->app_config->payments->reversible_deposits_lookback;

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'write'
    })->db->dbic;

if ($input{create}) {
    try {
        validate($db, %input);
        my $result = $db->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM payment.doughflow_method_create(?, ?, ?, ?, ?, ?, ?)',
                    undef,
                    @input{qw/payment_processor payment_method reversible deposit_poi_required poo_required withdrawal_supported payment_category/});
            });
        $success = format_details($result) . ' method has been created';
    } catch ($e) {
        $error = "Failed to create method: $e.";
    }
}

if (my $id = $input{edit}) {
    $item = $db->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM payment.doughflow_method_list(?, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', undef, $id);
        });
    $error = 'Method does not exist' unless $item;
}

if ($input{update_confirm}) {
    try {
        validate($db, %input);
        my $result = $db->run(
            fixup => sub {
                $_->selectrow_hashref(
                    'SELECT * FROM payment.doughflow_method_update(?, ?, ?, ?, ?, ?, ?, ?)',
                    undef,
                    @input{
                        qw/update_confirm payment_processor payment_method reversible deposit_poi_required poo_required withdrawal_supported payment_category/
                    });
            });
        die "method may have been removed\n" unless $result;
        $success = format_details($result) . ' method has been updated';
    } catch ($e) {
        $error = "Failed to save method: $e.";
    }
}

if (my $id = $input{delete_confirm}) {
    try {
        my ($result) = $db->run(
            fixup => sub {
                $_->selectrow_array('SELECT * FROM payment.doughflow_method_delete(?)', undef, $id);
            });
        die "method may have been removed\n" unless $result;
        $success = 'Method deleted successfully';
    } catch ($e) {
        $error = "Failed to delete method: $e.";
    }
}

my $limit  = 50;
my $offset = $input{offset} || 0;
my $filter = {$input{methods_sort_option} // 0 => $input{filter_by} //= 0};

my $methods = $db->run(
    fixup => sub {
        $_->selectall_arrayref(
            'SELECT * FROM payment.doughflow_method_list(NULL, ?, ?, ?, ?, ?, ?, ?)',
            {Slice => {}},
            $input{show_all}             ? undef                        : $reversible_days,
            $filter->{payment_processor} ? $filter->{payment_processor} : undef,
            $filter->{payment_method}    ? $filter->{payment_method}    : undef,
            $filter->{payment_category}  ? $filter->{payment_category}  : undef,
            $input{methods_sort_option}  ? $input{methods_sort_option}  : undef,
            $limit + 1,    # one more to detect if next page is available
            $offset,
        );
    });

my $next = @$methods > $limit ? $offset + $limit         : undef;
my $prev = $offset > 0        ? max(0, $offset - $limit) : undef;
$methods = [splice(@$methods, 0, $limit)];

BOM::Backoffice::Request::template()->process(
    'backoffice/doughflow_method_manage.tt',
    {
        broker          => $broker,
        methods         => $methods,
        item            => $item,
        delete          => $input{delete},
        success         => $success,
        error           => $error,
        check           => $check,
        reversible_days => $reversible_days,
        show_all        => $input{show_all},
        filter_by       => $input{filter_by},
        sort_by         => $input{methods_sort_option},
        offset          => $offset,
        prev            => $prev,
        next            => $next,
    });

sub validate {
    my @args  = @_;
    my $db    = shift @args;
    my %input = @args;

    die "processor and method are both empty\n" unless $input{payment_processor} or $input{payment_method};
    die "method must be empty if Deposit POI Required is enabled\n" if $input{deposit_poi_required} and $input{payment_method};

    my ($exist_id) = $db->run(
        fixup => sub {
            $_->selectrow_array('SELECT id FROM payment.doughflow_method_list(NULL, NULL, ?, ?, NULL, NULL, NULL, NULL)',
                undef, @input{qw(payment_processor payment_method)});
        });

    die "duplicates an exising entry\n" if $exist_id and $exist_id ne ($input{update_confirm} // '');
}

sub format_details {
    my $res = shift;
    return 'Definition for processor=' . ($res->{payment_processor} || '[empty]') . ', method=' . ($res->{payment_method} || '[empty]');
}

code_exit_BO();
