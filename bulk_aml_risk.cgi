#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::User::Client;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Bulk AML Risk Classification");

my $loginids                = uc(request()->param('risk_loginids') // '');
my $selected_aml_risk_level = request()->param('selected_aml_risk_level') // '';

# check invalid action
if (not any { $selected_aml_risk_level eq $_->{value} } get_aml_risk_classicications()) {
    code_exit_BO('ERROR : AML risk classification is not specified.');
}

unless ($loginids) {
    code_exit_BO('ERROR : No loginid is specified.');
}

Bar("Bulk AML Risk Classification");

my $error_msg = '';
my @processed_ids;

foreach my $login_id (split(/\s+/, $loginids)) {
    next if any { $_ eq $login_id } @processed_ids;

    my $client = eval { BOM::User::Client::get_instance({'loginid' => $login_id}) };
    if (not $client) {
        $error_msg .= "<br /><font color=red><b>ERROR :</b></font>&nbsp;&nbsp; Loginid was not found <b>" . encode_entities($login_id) . "</b>. \n";
        next;
    }

    if ($client->is_virtual) {
        $error_msg .=
            "<br /><font color=red><b>ERROR :</b></font>&nbsp;&nbsp; Virtual account was igonred <b>" . encode_entities($login_id) . "</b>. \n";
        next;
    }

    # login_id first, then sibling liginids
    my @siblings = sort { ($a ne $login_id) <=> ($b ne $login_id) } $client->user->bom_loginids;
    foreach my $sibling_loginid (@siblings) {
        push @processed_ids, $sibling_loginid;
        my $sibling = ($sibling_loginid eq $login_id) ? $client : BOM::User::Client::get_instance({'loginid' => $sibling_loginid});

        unless ($sibling->is_virtual or not check_update_needed($client, $sibling, 'aml_risk_classification')) {
            $sibling->aml_risk_classification($selected_aml_risk_level);
            $sibling->save();

            print "<br /><font color=green><b>SUCCESS :</font></b>&nbsp;&nbsp; "
                . link_for_clientloginid_edit($sibling_loginid)
                . " AML Risk Classification = $selected_aml_risk_level"
                . ($sibling_loginid eq $login_id ? '' : ' (sibling to ' . $login_id . ')') . "\n";
        }
    }
}

print $error_msg if $error_msg;

code_exit_BO();
