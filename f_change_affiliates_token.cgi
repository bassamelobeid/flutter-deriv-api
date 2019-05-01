#!/etc/rmg/bin/perl
package main;

=pod
 
=head1 DESCRIPTION

This script responsible to handle create or edit of the affiliate token
(which only accessible by Marketing team)
and required DCC Token to approve the create or edit of the affiliate token

=cut

use strict;
use warnings;
use f_brokerincludeall;

BOM::Backoffice::Sysinit::init();

my $input = request()->params;

my $clerk = BOM::Backoffice::Auth0::get_staffname();

PrintContentType();

my $loginid         = $input->{loginid}         // '';
my $ClientLoginid   = $input->{ClientLoginid}   // '';
my $affiliate_token = $input->{affiliate_token} // '';
my $prev_dcc        = $input->{DCcode}          // '';

my $self_post = request()->url_for('backoffice/f_change_affiliates_token.cgi');

# given a bad-enough loginID, BrokerPresentation can die, leaving an unformatted screen..
# let the client-check offer a chance to retry.
BrokerPresentation("AFFILIATE TOKEN DCC");

# Not available for Virtual Accounts
if (($loginid =~ /^VR/) || ($loginid =~ /^MT\d+$/)) {
    Bar("CHANGE Client AFFILIATE TOKEN DCC");
    print '<p class="aligncenter">' . localize('We\'re sorry but the Affiliate Token is not available for this type of Accounts.') . '</p>';
    code_exit_BO();
}

BOM::Backoffice::Request::template()->process(
    'backoffice/change_affiliates_token.html.tt',
    {
        clerk           => encode_entities($clerk),
        loginid         => $loginid,
        ClientLoginid   => $ClientLoginid,
        affiliate_token => $affiliate_token,
        prev_dcc        => $prev_dcc
    });

if ($input->{EditAffiliatesToken}) {

    #Error checking
    code_exit_BO(_get_display_error_message("ERROR: Please provide client loginid"))       unless $input->{ClientLoginid};
    code_exit_BO(_get_display_error_message("ERROR: Please provide a dual control code"))  unless $input->{DCcode};
    code_exit_BO(_get_display_error_message("ERROR: You must check the verification box")) unless $input->{verification};

    code_exit_BO(_get_display_error_message("ERROR: Invalid operation")) unless $input->{EditAffiliatesToken} eq 'Edit affiliates token';
    code_exit_BO(_get_display_error_message("ERROR: Invalid affiliate_token provided!"))
        if $affiliate_token and $affiliate_token !~ m/^[a-zA-Z0-9-_]+$/;

    my $ClientLoginid  = trim(uc $input->{ClientLoginid});
    my $well_formatted = check_client_login_id($ClientLoginid);
    code_exit_BO(_get_display_error_message("ERROR: Invalid loginid provided!")) unless $well_formatted;
    if (($ClientLoginid =~ /^VR/) || ($ClientLoginid =~ /^MT\d+$/)) {
        code_exit_BO(_get_display_error_message("ERROR: Affiliate Token is not available for this type of Accounts.!"));
    }

    my $client = try { return BOM::User::Client->new({loginid => $ClientLoginid}) };
    code_exit_BO(
        qq[<p>ERROR: Client [$ClientLoginid] not found. </p>
                  <form action="$self_post" method="get">
                  Try Again: <input type="text" name="loginID" value="$ClientLoginid"></input>
                  </form>]
    ) unless $client;

    my $dcc_error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{EditAffiliatesToken}}
    )->validate_client_control_code($input->{DCcode}, $client->email, $client->binary_user_id);
    code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg())) if $dcc_error;

    # Get User clients to update them
    my @clients_to_update;
    my $user = $client->user;
    my @user_clients = $user->clients(include_disabled => 1);
    push @clients_to_update, grep { not $_->is_virtual } @user_clients;

    # Updates that apply to both active client and its corresponding clients
    foreach my $cli (@clients_to_update) {
        # Exclude metatrader clients
        next if ($cli->loginid =~ /^MT\d+$/);

        # Update myaffiliates_token
        $cli->myaffiliates_token($affiliate_token);

        if (not $cli->save) {
            code_exit_BO("<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $ClientLoginid</p></p>");
        }

        print "<p style=\"color:#eeee00; font-weight:bold;\">Client " . $cli->loginid . " saved</p>";
    }

    my $msg =
          Date::Utility->new->datetime . " "
        . " Edit affiliates token for "
        . $ClientLoginid
        . " by clerk=$clerk (DCcode="
        . ($input->{DCcode} // 'No DCode provided')
        . ") $ENV{REMOTE_ADDR}";

    BOM::User::AuditLog::log($msg, '', $clerk);

    $msg = 'Edit Affiliates Token completed successfully.';
    code_exit_BO(_get_display_message($msg));
}

code_exit_BO();
