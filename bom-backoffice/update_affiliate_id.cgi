#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use HTML::Entities;
use BOM::User::Client;

use BOM::Backoffice::Sysinit ();
use f_brokerincludeall;
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Database::UserDB;
use Set::Scalar;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("UPDATE AFFILIATE ID");

my $broker = request()->broker_code;

if ($broker eq 'FOG') {
    code_exit_BO('NOT RELEVANT FOR BROKER CODE FOG');
}

my $loginid  = encode_entities(request()->param('loginid') // "");
my $titlebar = "Update affiliate id for " . $loginid;
my $client   = BOM::User::Client->new({loginid => $loginid});
my $user     = $client->user;

my $affiliate_mt5_accounts_db = $user->dbic->run(
    fixup => sub {
        $_->selectall_arrayref(q{SELECT * FROM mt5.list_user_accounts(?)}, {Slice => {}}, $user->id);
    });

my @affiliate_mt5_accounts = map { $_->{mt5_account_id} } @$affiliate_mt5_accounts_db;

Bar($titlebar);

my $stash = {
    action        => request()->url_for('backoffice/update_affiliate_id.cgi'),
    url_to_client => request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $loginid}),
    mt5_accounts  => \@affiliate_mt5_accounts,
    broker        => $broker,
    loginid       => $loginid
};

BOM::Backoffice::Request::template()->process('backoffice/update_affiliate_id.html.tt', $stash) || die BOM::Backoffice::Request::template()->error(),
    "\n";

if (request()->http_method eq 'POST') {
    my $new_aff_id = request()->param('new_aff_id');

    if ($new_aff_id) {
        my $updated_mt5_accounts = $user->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    q{SELECT * FROM mt5.update_mt5_myaffiliate_id(?,?,?)},
                    {Slice => {}},
                    $user->id, $new_aff_id, \@affiliate_mt5_accounts
                );
            });

        my @actual_updated_accounts = map { $_->{update_mt5_myaffiliate_id} } $updated_mt5_accounts->@*;

        unless (scalar(@actual_updated_accounts) == 0) {
            print "Accounts are updated sucessfully with new affiliate id " . $new_aff_id;
        } else {
            print "Error : Accounts' affiliate IDs are not updated. Check Binary user ID has the correct MT5 accounts assigned.";
        }

    } else {
        print "Please enter a valid Affiliate ID";
    }

}

code_exit_BO();

