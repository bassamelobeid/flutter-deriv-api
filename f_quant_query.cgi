#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Date::Utility;

use BOM::User::Client;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();

use f_brokerincludeall;
BOM::Backoffice::Sysinit::init();

my $loginID         = uc(request()->param('loginID'));
my $encoded_loginID = encode_entities($loginID);
PrintContentType();
BrokerPresentation('Quant Query', '', '');
my $staff = BOM::Backoffice::Auth0::get_staff();

if ($loginID !~ /^(\D+)(\d+)$/) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $client = BOM::User::Client::get_instance({'loginid' => $loginID});
if (not $client) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $section_sep = '---';
my $bits_sep    = ':::';
my @reasons     = ('Disputed Settlement', 'Duplicate Purchase', 'Missing Market Data', 'Other');

if (my $il = request()->param('investigate_list')) {
    # Step one from the profit table
    $il = [$il] unless ref $il;

    my @message = (
        $client->loginid,
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
    foreach my $details (@$il) {
        my ($ref, $desc, $bought) = split /$bits_sep/, $details;
        push @message, $ref . ' [' . $bought . '] (' . $desc . ")";
        $reflist .= $ref . ', ';
    }
    $reflist = substr($reflist, 0, -2);

    BOM::Backoffice::Request::template()->process(
        'backoffice/quant_query.html.tt',
        {
            reasons => \@reasons,
            loginID => $loginID,
            reflist => $reflist,
            details => join($bits_sep, @message),
        }) || die BOM::Backoffice::Request::template()->error();

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

    my @to_list = ('x-quants@binary.com', 'x-cs@binary.com', $staff->{email});
    push @to_list, 'triage@binary.com' if (request()->param('inform_triage'));

    if (
        send_email({
                from    => 'QQ from ' . $staff->{nickname} . ' <qq@binary.com>',
                to      => join(',', @to_list),
                subject => '[QQ] ' . $client->loginid . ': ' . $reason . ' - ' . request()->param('reflist'),
                message => [
                    'Reported by: ' . $staff->{nickname} . ' (' . $staff->{email} . ')',
                    $section_sep, (split /$bits_sep/, request()->param('details')),
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
