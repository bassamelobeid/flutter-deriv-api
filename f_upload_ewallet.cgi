#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use File::Temp ();
use File::Copy;
use HTML::TreeBuilder;
use Path::Tiny;
use Scalar::Util qw(looks_like_number);

use BOM::Backoffice::PlackHelpers qw( PrintContentType  PrintContentType_excel);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use Date::Utility;
use BOM::Backoffice::Auth0;

my $staff = BOM::Backoffice::Auth0::get_staffname();
use BOM::Backoffice::Request qw(request);

my %input = %{request()->params};

# Upload
my $calendar_hash;
my $calendar_name;

if ($input{upload_coinpayment_html}) {
    my $cgi  = CGI->new;
    my $file = $cgi->param('filetoupload');

    #Turn HTML into CSV
    my $tree = HTML::TreeBuilder->new;
    $tree->parse_file($file);

    my @rows = $tree->look_down(
        _tag => 'tr',
    ) or die "Couldn't find any coinpayment data rows";

    PrintContentType_excel('coinpayment-output.csv');
    print 'TRANSACTION YEAR,TRANSACTION_MONTH,TRANSACTION DATE AND TIME,TXID,ADDRESS,CURRENCY,AMOUNT,FEE,NET AMOUNT,CONFIRMATION,STATUS' . "\n";

    my $i = 0;
    for (@rows) {
        $i++;
        next if $i == 1;

        my $line  = {};
        my @cells = $_->content_list;
        die("Expected 5 cells but got " . 0 + @cells) unless @cells == 5;

        my $date_time          = $cells[0]->as_text;
        my @datetime_breakdown = split(' ', $date_time);
        my @date_breakdown     = split('/', $datetime_breakdown[0]);
        my $month              = $date_breakdown[0];
        my $year               = $date_breakdown[2];

        my @cell1_arr   = split('TXID:', $cells[1]->as_text);
        my $txid        = $cell1_arr[1];
        my @address_arr = split('Address: ', $cell1_arr[0]);
        my $address     = $address_arr[1];

        my @amount_arr = split(' ', $cells[2]->as_text);
        my $amount     = $amount_arr[0];
        my $ccy        = $amount_arr[6];
        my $minus_fee  = $amount_arr[3];
        my $net        = $amount_arr[5];

        die("Amount, amount minux fee and Net must be a number.")
            if (not looks_like_number($amount) or not looks_like_number($minus_fee) or not looks_like_number($net));

        my $confirms = $cells[3]->as_text;
        my $status   = $cells[4]->as_text;

        print $year . ','
            . $month . ','
            . $date_time . ','
            . $txid . ','
            . $address . ','
            . $ccy . ','
            . $amount . ','
            . $minus_fee . ','
            . $net . ','
            . $confirms . ','
            . $status . "\n";
    }

} elsif ($input{upload_ewallet_exchange_csv}) {
    my $cgi      = CGI->new;
    my $file     = $cgi->param('filetoupload');
    my $fh       = File::Temp->new(SUFFIX => '.html');
    my $filename = $fh->filename;
    copy($file, $filename);

    my @lines = Path::Tiny::path($filename)->lines;

    die "Empty file" if scalar(@lines) < 2;

    PrintContentType_excel('ewallet_exchange-output.csv');
    my $i = 0;

    foreach my $line (@lines) {
        if ($i++ < 1) {
            print $line;
            next;
        }
        print $line =~ s/,/./gr;
    }

}

code_exit_BO();
