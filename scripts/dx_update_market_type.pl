use strict;
use warnings;

use BOM::Database::UserDB;
use BOM::Config;
use Getopt::Long;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => 'info';
use Syntax::Keyword::Try;
use Pod::Usage;

=head1 NAME

dx_update_market_type.pl

=head1 SYNOPSIS

./dx_update_market_type.pl [options] 

=head1 NOTE

This script looks for DerivX users with only financial 
or only synthetic accounts and sets the 'market_type' 
attribute in the 'users.loginid' table to 'all'

=head1 OPTIONS

=over 20

=item B<-h>, B<--help>

Brief help message

=item B<-a>, B<--account_type>

DerivX server type ('real' or 'demo')

=item B<-m>, B<--market_type>

Market type ('financial' or 'synthetic')

=back

=cut

my $account_type = 'real';
my $market_type  = 'financial';
my $help         = 0;

GetOptions(
    'a|account_type=s' => \$account_type,
    'm|market_type=s'  => \$market_type,
    'h|help!'          => \$help,
);

pod2usage(1) if $help;

my $other_market_type = $market_type eq 'financial' ? 'synthetic' : 'financial';
my $user_db           = BOM::Database::UserDB::rose_db();

my @servers = ('demo', 'real');

sub update_dx_accounts {
    $log->infof("Updating %s %s 'market_type' via PSQL...", $account_type, $market_type);

    try {
        $user_db->dbic->run(
            fixup => sub {
                my $query = $_->do(
                    "SET statement_timeout = 0;
                    UPDATE users.loginid AS u
                    SET attributes = jsonb_set(u.attributes, '{market_type}', '\"all\"')
                    WHERE u.status IS NULL 
                    AND u.platform = 'dxtrade' 
                    AND u.account_type = ?
                    AND u.attributes->> 'market_type' = ?
                    AND NOT EXISTS (
                        SELECT *
                        FROM users.loginid AS u2
                        WHERE u2.attributes->> 'market_type' = ?
                        AND u2.platform = 'dxtrade'
                        AND u2.status IS NULL
                        AND u2.account_type = ?
                        AND u2.binary_user_id=u.binary_user_id
                    );",
                    undef,
                    $account_type, $market_type, $other_market_type, $account_type
                );
            });
    } catch ($e) {
        $log->errorf("An error has occured while fetching %s %s accounts : %s", $account_type, $market_type, $e);
        return;
    };
    $log->infof("Finished updating %s %s 'market_type'...", $account_type, $market_type);
}

update_dx_accounts();
