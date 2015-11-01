#!/usr/bin/perl
package main;
use strict;
use warnings;

use Date::Utility;
use JSON qw(to_json from_json);

use BOM::Platform::Client;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();

use f_brokerincludeall;
BOM::Platform::Sysinit::init();

my $loginID = uc(request()->param('loginID'));

PrintContentType();
BrokerPresentation('Quant Query', '', '');
my $staff = BOM::Backoffice::Auth0::from_cookie();

if ($loginID !~ /^(\D+)(\d+)$/) {
    print "Error : wrong eoginID ($loginID) could not get client instance";
    code_exit_BO();
}

my $client = BOM::Platform::Client::get_instance({'loginid' => $loginID});
if (not $client) {
    print "Error : wrong loginID ($loginID) could not get client instance";
    code_exit_BO();
}

my $section_sep = '---';
my @reasons = ('Disputed Settlement', 'Duplicate Purchase', 'Missing Market Data', 'Other');

if (my $il = request()->param('investigate_list')) {
    # Step one from the profit table
    $il = [$il] unless ref $il;

    my @message = (
        sprintf("%s: %s %s (%s)", map { $client->$_ // '' } (qw(loginid email full_name residence))),
        sprintf(
            "%s",
            request()->url_for(
                'backoffice/f_profit_table.cgi',
                {
                    loginID => $client->loginid,
                    broker  => $client->broker
                })
        ),
        $section_sep
    );
    my $reflist;
    foreach my $details (map { from_json($_) } @$il) {
        push @message, '- ' . $details->{ref} . ' [' . $details->{bought} . '] (' . $details->{desc} . ")";
        $reflist .= $details->{ref} . ', ';
    }
    $reflist = substr($reflist, 0, -2);

    BOM::Platform::Context::template->process(
        'backoffice/quant_query.html.tt',
        {
            reasons => \@reasons,
            loginID => $loginID,
            reflist => $reflist,
            details => to_json(\@message),
        }) || die BOM::Platform::Context::template->error();

    code_exit_BO();
} elsif (my $desc = request()->param('desc')) {
    # Step two from this page
    my $reason = request()->param('reason');

    my $cgi = request()->cgi;

    my @attach;
    if (my $file = $cgi->param('query_doc')) {
        @attach = (
            attachment => $cgi->tmpFileName($file),
            att_type   => $cgi->uploadInfo($file)->{'Content-Type'},
        );
    }

    if (
        send_email({
                from    => 'QQ from ' . $staff->{nickname} . ' <qq@binary.com>',
                to      => 'x-quants@binary.com,x-cs@binary.com,' . $staff->{email},
                subject => '[QQ] ' . $client->loginid . ': ' . $reason . ' - ' . request()->param('reflist'),
                message => [
                    'Reported by: ' . $staff->{nickname} . ' (' . $staff->{email} . ')',
                    $section_sep, @{from_json(request()->param('details'))},
                    $section_sep, $reason . ':',
                    $desc, $section_sep,
                ],
                @attach,
            }))
    {
        print "Quant query sent";
        code_exit_BO();
    }
}
# Not supposed to make it here.

print "Something went wrong, try again.";

code_exit_BO();
