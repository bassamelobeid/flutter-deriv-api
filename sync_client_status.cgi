#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use HTML::Entities;

use BOM::User::Client;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

sub success { return '<b><font color="green">SUCCESS:</font>&nbsp;' . shift . '</b>' }
sub error   { return '<b><font color="red">ERROR:</font>&nbsp;' . shift . '</b>' }

sub link_to_edit_client {
    my $loginid = shift->loginid;

    return
          '<a href="'
        . request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => encode_entities($loginid)}) . '">'
        . encode_entities($loginid) . '</a>';
}

sub notify_copy_status_succeeded {
    my ($client, $status_code) = @_;

    my $client_status_ref = $client->status->$status_code;
    my $loginid_link      = link_to_edit_client($client);
    my $reason            = encode_entities($client_status_ref->{reason});
    my $clerk             = encode_entities($client_status_ref->{staff_name});
    my $broker_code       = $client->broker_code;
    my $untrusted_type    = get_untrusted_type_by_code($status_code);
    my $linktype          = $untrusted_type->{linktype};

    return success("<b>$loginid_link $reason ($clerk)</b> has been saved to <b>$broker_code.$linktype</b><br/>");
}

sub notify_status_already_set {
    my ($client, $status_code) = @_;

    my $client_status_ref = $client->status->$status_code;
    my $loginid_link      = link_to_edit_client($client);
    my $reason            = encode_entities($client_status_ref->{reason});
    my $clerk             = encode_entities($client_status_ref->{staff_name});
    my $broker_code       = $client->broker_code;
    my $untrusted_type    = get_untrusted_type_by_code($status_code);
    my $linktype          = $untrusted_type->{linktype};

    return success("<b>$loginid_link $reason ($clerk)</b> is already saved to <b>$broker_code.$linktype</b><br/>");
}

sub notify_copy_status_failed {
    my ($source_client, $status_code, $target_client) = @_;
    my $target_loginid_link = link_to_edit_client($target_client);
    my $client_status_ref   = $source_client->status->$status_code;
    my $reason              = encode_entities($client_status_ref->{reason});
    my $clerk               = encode_entities($client_status_ref->{staff_name});
    my $broker_code         = $source_client->broker_code;
    my $untrusted_type      = get_untrusted_type_by_code($status_code);
    my $linktype            = $untrusted_type->{linktype};

    return error("<b>$target_loginid_link $reason ($clerk)</b> has NOT been saved to <b>$broker_code.$linktype</b><br/>");
}

sub notify_remove_status_succeeded {
    my ($client, $status_code) = @_;
    my $loginid_link   = link_to_edit_client($client);
    my $broker_code    = $client->broker_code;
    my $untrusted_type = get_untrusted_type_by_code($status_code);
    my $linktype       = $untrusted_type->{linktype};

    return success("<b>$loginid_link</b> has been removed from <b>$broker_code.$linktype</b><br/>");
}

sub notify_remove_status_failed {
    my ($client, $status_code) = @_;
    my $loginid_link   = link_to_edit_client($client);
    my $broker_code    = $client->broker_code;
    my $untrusted_type = get_untrusted_type_by_code($status_code);
    my $linktype       = $untrusted_type->{linktype};

    return success("<b>$loginid_link</b> has NOT been removed from <b>$broker_code.$linktype</b><br/>");
}

sub handle_request {
    my ($client, $action, $status_code) = @_;

    if ($action eq 'copy') {
        my $updated_client_loginids = $client->copy_status_to_siblings($status_code, BOM::Backoffice::Auth0::get_staffname());

        my @notifications = map {
            my $sibling = $_;

            if (grep { $_ eq $sibling->loginid } @{$updated_client_loginids}) {
                notify_copy_status_succeeded($sibling, $status_code);
            } elsif ($sibling->status->$status_code) {
                notify_status_already_set($sibling, $status_code);
            } else {
                notify_copy_status_failed($client, $status_code, $sibling);
            }
        } @{$client->siblings()};

        return (@notifications, '<br/><br/>Go back to ' . link_to_edit_client($client) . '<br/>');
    } elsif ($action eq 'remove') {
        my $updated_client_loginids = $client->clear_status_and_sync_to_siblings($status_code);

        my @notifications = map {
            my $client = $_;

            if (grep { $_ eq $client->loginid } @{$updated_client_loginids}) {
                notify_remove_status_succeeded($client, $status_code);
            } else {
                notify_remove_status_failed($client, $status_code);
            }
        } $client->user->clients_for_landing_company($client->landing_company->short);    # must include current client

        return (@notifications, '<br/><br/>Go back to ' . link_to_edit_client($client) . '<br/>');
    }

    return code_exit_BO();
}

PrintContentType();

my $loginid     = request()->param('loginid');
my $action      = lc request()->param('action');
my $status_code = lc request()->param('status_code');

if (!$action) {
    BrokerPresentation('SYNC/REMOVE CLIENT STATUS');
    Bar('SYNC/REMOVE CLIENT STATUS');

    print error('No action has been provided');
    return code_exit_BO();
}

if ($action eq 'copy') {
    BrokerPresentation('SYNC CLIENT STATUS');
    Bar('COPY STATUS TO LANDING COMPANY SIBLINGS');
} elsif ($action eq 'remove') {
    BrokerPresentation('REMOVE CLIENT STATUS');
    Bar('REMOVE CLIENT STATUS FROM ALL LANDING COMPANY ACCOUNTS');
} else {
    BrokerPresentation('SYNC/REMOVE CLIENT STATUS');
    Bar('SYNC/REMOVE CLIENT STATUS');

    print error('Unknown action "' . $action . '" provided');
    return code_exit_BO();
}

if (!$loginid) {
    print error('No client login ID has been provided');
    return code_exit_BO();
}

if (!$status_code) {
    print error('No status code has been provided');
    return code_exit_BO();
}

my $client = BOM::User::Client->new({loginid => $loginid});

print join '', handle_request($client, $action, $status_code);

code_exit_BO();
