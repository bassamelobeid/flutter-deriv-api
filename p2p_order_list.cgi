#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use Data::Dumper;
BOM::Backoffice::Sysinit::init();

use BOM::Database::ClientDB;
use Syntax::Keyword::Try;
use Scalar::Util qw(looks_like_number);

my $cgi = CGI->new;

PrintContentType();
BrokerPresentation('P2P ORDERS MANAGEMENT');

my %input  = %{request()->params};
my $broker = request()->broker_code;

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'replica'
    })->db->dbic;

$input{limit} = ($input{limit} && int($input{limit}) > 0) ? int($input{limit}) : 30;
$input{page}  = ($input{page}  && int($input{page}) > 0)  ? int($input{page})  : 1;

$input{offset} = ($input{page} - 1) * $input{limit};

for my $field (qw(order_id advert_id loginID status limit offset)) {
    code_exit_BO($input{$field} . ' is not numeric')
        if $field =~ /^(order_id|advert_id|limit|offset)$/ && $input{$field} && !looks_like_number($input{$field});
    next if $input{$field};
    undef $input{$field};
}

my $orders = $db->run(
    fixup => sub {
        $_->selectall_arrayref(
            'SELECT * FROM p2p.order_list(?, ?, ?, ?, ?, ?)',
            {Slice => {}},
            @input{qw/order_id advert_id loginID/},
            $input{status} ? [$input{status}] : undef,
            @input{qw/limit offset/},
        );
    }) // [];

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/order_list.tt',
    {
        input  => \%input,
        orders => $orders,
    });

code_exit_BO();
