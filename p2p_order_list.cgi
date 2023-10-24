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
use BOM::User::Utility;
use Syntax::Keyword::Try;
use Scalar::Util          qw(looks_like_number);
use Format::Util::Numbers qw(financialrounding);
use Date::Utility;

my $cgi = CGI->new;

PrintContentType();
BrokerPresentation('P2P ORDERS MANAGEMENT');

my %input  = %{request()->params};
my $broker = request()->broker_code;

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'backoffice_replica'
    })->db->dbic;

$input{limit} = ($input{limit} && int($input{limit}) > 0) ? int($input{limit}) : 30;
$input{page}  = ($input{page}  && int($input{page}) > 0)  ? int($input{page})  : 1;

$input{offset} = ($input{page} - 1) * $input{limit};

for my $field (qw(order_id advert_id loginID status country limit offset)) {
    code_exit_BO("$field value provided is not an integer!")
        if $field =~ /^(order_id|advert_id|limit|offset)$/ && $input{$field} && $input{$field} !~ m/^[0-9]+$/;
    delete $input{$field} unless $input{$field};
}

my $orders = $db->run(
    fixup => sub {
        $_->selectall_arrayref(
            'SELECT * FROM p2p.order_search(?, ?, ?, ?, ?, ?, ?, ?)',
            {Slice => {}},
            @input{qw/order_id advert_id loginID status country sort_ord limit offset/},
        );
    });

for my $order (@$orders) {
    $order->{$_}            = Date::Utility->new($order->{$_})->datetime for qw(created_time expire_time);
    $order->{rate}          = BOM::User::Utility::p2p_rate_rounding($order->{rate}, display => 1);
    $order->{price_display} = financialrounding('amount', $order->{local_currency},   $order->{rate} * $order->{amount});
    $order->{amount}        = financialrounding('amount', $order->{account_currency}, $order->{amount});
}

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/order_list.tt',
    {
        input     => \%input,
        orders    => $orders,
        countries => request()->brand->countries_instance->countries_list,
    });

code_exit_BO();
