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
use Date::Utility;
use BOM::Config::P2P;
use List::Util qw(max);

use constant PAGE_LIMIT => 50;

my $cgi = CGI->new;

PrintContentType();
BrokerPresentation('P2P ADVERTISER SEARCH');

my %input  = %{request()->params};
my $broker = request()->broker_code;

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'backoffice_replica'
    })->db->dbic;

$input{sort_order} = 'asc' unless ($input{sort_order} // '') eq 'desc';
$input{sort_by}   //= 'id';
$input{date_from} //= Date::Utility->new->minus_months(3)->date;
$input{offset}    //= 0;

my $results = [];
$results = $db->run(
    fixup => sub {
        $_->selectall_arrayref(
            'SELECT * FROM p2p.advertiser_search(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            {Slice => {}},
            @input{qw/nickname email residence date_from pa_status include_disabled sort_by sort_order offset/},
            PAGE_LIMIT + 1,
        );
    }) if $input{search};

my %link_params;
for my $field (qw(id created_time loginid nickname trade_band email residence pa_status p2p_buy p2p_sell)) {
    $link_params{$field} = {
        %input,
        sort_by    => $field,
        sort_order => ($input{sort_by} eq $field and $input{sort_order} eq 'asc') ? 'desc' : 'asc'
    };
}

$link_params{prev} = $input{offset}         ? {%input, offset => max(0, $input{offset} - PAGE_LIMIT)} : undef;
$link_params{next} = @$results > PAGE_LIMIT ? {%input, offset => $input{offset} + PAGE_LIMIT}         : undef;

splice(@$results, PAGE_LIMIT);

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_advertiser_list.tt',
    {
        input       => \%input,
        results     => $results,
        link_params => \%link_params,
        sort_flag   => {$input{sort_by} => $input{sort_order} eq 'asc' ? '&#9660;' : '&#9650;'},
        countries   => BOM::Config::P2P::available_countries,
    });

code_exit_BO();
