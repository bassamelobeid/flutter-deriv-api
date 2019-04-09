#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Date::Utility;

BOM::Backoffice::Sysinit::init();
my $input = request()->params;
my $clerk = BOM::Backoffice::Auth0::get_staffname();

Bar("Make dual control code");

# Error checks

code_exit_BO("Please provide a transaction type.") unless $input->{transtype};
code_exit_BO("Invalid transaction type") unless ($input->{transtype} =~ /^Anonymize client|Delete customerio record|Edit affiliates token$/);
code_exit_BO("ERROR: Please provide client loginid") unless ($input->{clientloginid});

$input->{clientloginid} = trim(uc $input->{clientloginid});
my $well_formatted = check_client_login_id($input->{clientloginid});
code_exit_BO("Invalid loginid provided!") unless $well_formatted;

my $client = BOM::User::Client::get_instance({
    'loginid'    => uc($input->{'clientloginid'}),
    db_operation => 'replica'
});
code_exit_BO("ERROR: " . encode_entities($input->{'clientloginid'}) . " does not exist") if (not $client);

my $code = BOM::DualControl->new({
        staff           => $clerk,
        transactiontype => $input->{transtype}})->client_anonymization_control_code($input->{clientloginid});

#Logging

my $message =
      "The dual control code created by $clerk  (for a "
    . $input->{transtype}
    . ") for "
    . $input->{clientloginid}
    . " is: $code This code is valid for 1 hour (from "
    . Date::Utility->new->datetime_ddmmmyy_hhmmss
    . ") only.";

BOM::User::AuditLog::log($message, '', $clerk);

# Display

print '<p>'
    . 'DCC: <br>'
    . '<textarea rows="5" cols="100" readonly="readonly">'
    . encode_entities($code)
    . '</textarea><br>'
    . 'This code is valid for 1 hour from now: UTC '
    . Date::Utility->new->datetime_ddmmmyy_hhmmss . '<br>'
    . 'Creator: '
    . $clerk . '<br>' . '</p>';

print "<p>Note: "
    . encode_entities($input->{clientloginid}) . " is "
    . encode_entities($client->salutation) . ' '
    . encode_entities($client->first_name) . ' '
    . encode_entities($client->last_name)
    . ' current email is '
    . encode_entities($client->email);

code_exit_BO();
