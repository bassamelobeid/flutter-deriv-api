#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw( request template );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use Date::Utility;

use BOM::Platform::Event::Emitter;
use BOM::User::Client;

PrintContentType();

my $input = request()->params();

trim($input->{from});
trim($input->{to});

# format to expect for regex checking
my $date_format = qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/;

my $from_date = eval { Date::Utility->new($input->{from})->epoch() };
my $to_date   = eval { Date::Utility->new($input->{to})->epoch() };

if (!$input->{from} || !$input->{to} || $input->{from} !~ m/$date_format/ || $input->{to} !~ m/$date_format/ || !$from_date || !$to_date) {
    print "Invalid from date or to date!<p>" . "Please enter the format in the form of (yyyy-mm-dd HH:MM:SS) example: 2012-01-25 01:20:30";
    code_exit_BO();
}

unless ($to_date > $from_date) {
    print "From date must be before To date for sending statement";
    code_exit_BO();
}

# we do not allow payment agents to request for statement
# as that may cause the statement queue to get stuck
my $client = BOM::User::Client->new({loginid => uc($input->{client_id})});
if ($client->payment_agent) {
    print "Sending statements to payment agents is currently disabled.";
    code_exit_BO();
}

my $params = {
    source    => 1,
    loginid   => $input->{client_id},
    date_from => $from_date,
    date_to   => $to_date,
};

BOM::Platform::Event::Emitter::emit('email_statement', $params);

BrokerPresentation('Email statement has been sent!');

my $self_href = request()->url_for(
    'backoffice/f_clientloginid_edit.cgi',
    {
        loginID => $input->{client_id},
        broker  => $input->{broker}});

code_exit_BO(
    qq[
        <form action="$self_href" method="POST">
            <input type="submit" value="back to client details"/>
        </form>
    ]
);

