use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize request);

my $clientdb = BOM::Database::ClientDB->new( { broker_code => 'MF' } )->db->dbic;
my $brand = request()->brand;

sub send_email {
    my ($client_email, $balance) = @_;
    
    my $email_subject = localize('Disabling');
    
    my $email_content = localize('Dear Valued Customer,') . "\n\n" 
    $email_content .= localize("We regret to inform you that to remain compliant with applicable international laws governing online trading, we will be closing all clients' accounts in France.");
    
    if ($balance == 0) {
        $email_content .= localize('As there is no balance in your account, we have disabled your account.') . "\n\n";
    } else {
        $email_content .= localize('Please withdraw your money from your Binary.com account by going to this cashier’s section: https://www.binary.com/en/cashier/forwardws.html?action=withdraw') . "\n\n";
    }
    
    $email_content .= localize('We would like to thank you for your support thus far.') . "\n\n";
    $email_content .= localize('Please contact us at <a href="mailto:support@binary.com">support@binary.com</a> if you have any questions.') . "\n\n";
    
    send_email({
        from                  => $brand->emails('support'),
        to                    => $client_email,
        subject               => $email_subject,
        message               => [$email_content],
        use_email_template    => 1,
        email_content_is_html => 1,
    });
    
    return undef
    
}

# Get the following from MF database: email address, balance
my @fr_residence_clients = @{
    $clientdb->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT cli.loginid, cli.email AS email, COALESCE(ta.balance, 0) AS balance
                FROM betonmarkets.client as cli
                left join transaction.account AS ta ON cli.loginid = ta.client_loginid
                 where cli.residence = 'fr'",
                { Slice => {} } );
        }
    )
};

$clientdb->txn(
    fixup => sub {
        foreach my $fr_client (@fr_residence_clients) {
            my $email = $fr_client->{email};
            my $balance = $fr_client->{balance};
            
            # If there is balance, mark as unwelcome. Otherwise, disable
            my $status = $balance == 0 ? 'disabled' : 'unwelcome';
            
            send_email($email, $balance);
            
            # Insert status
            $clientdb->run(
                ping => sub {
                    my $sth = $_->prepare(
                        'INSERT INTO betonmarkets.client_status(client_loginid, status_code, staff_name, reason) VALUES (?,?,?,?)'
                    );
                    $sth->execute($fr_client->{loginid}, $status, 'SYSTEM', 'No binary options for french clients');
                }
            );
        }
    }
);