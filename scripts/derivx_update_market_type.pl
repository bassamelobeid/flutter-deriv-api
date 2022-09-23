use strict;
use warnings;

use BOM::Database::UserDB;
use BOM::Config;
use Getopt::Long;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Log::Any::Adapter qw(Stderr), log_level => 'info';
use Pod::Usage;
use BOM::User::Client;
use BOM::User;
use BOM::Rules::Engine;

=head1 NAME

derivx_accounts_merging.pl

=head1 SYNOPSIS

./derivx_update_market_type.pl [options] 

=head1 NOTE

This script looks for DerivX users with only financial 
or only synthetic accounts and sets the 'market_type' 
attribute in the 'users.loginid' table to 'all'

=head1 OPTIONS

=over 20

=item B<-h>, B<--help>

Brief help message

=item B<-a>, B<--account_type>

MT5 server type ('real' or 'demo')

=item B<-m>, B<--market_type>

Market type ('financial' or 'synthetic')

=back

=cut

my $account_type = 'demo';
my $market_type  = 'financial';
my $help         = 0;

use constant {
    DX_CLEARING_CODE => 'default',
};

GetOptions(
    'a|account_type=s' => \$account_type,
    'm|market_type=s'  => \$market_type,
    'h|help!'          => \$help,
);

pod2usage(1) if $help;

sub get_dx_financial_accounts {

    $log->infof("Fetching and updating DerivX %s %s accounts...", $account_type, $market_type);

    my $user_db           = BOM::Database::UserDB::rose_db();
    my $other_market_type = $market_type eq 'financial' ? 'synthetic' : 'financial';
    my $updated_loginids;

    try {
        $updated_loginids = $user_db->dbic->run(
            fixup => sub {
                my $query = $_->prepare(
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
                                   AND u2.account_type = ?
                                   AND u2.binary_user_id=u.binary_user_id
                            )
                        RETURNING u.loginid"
                );
                $query->execute($account_type, $market_type, $other_market_type, $account_type);
                $query->fetchall_arrayref();
            });
    } catch ($e) {
        $log->errorf("An error has occured while fetching %s %s accounts : %s", $account_type, $market_type, $e);
        return;
    };

    foreach my $updated_loginid (@$updated_loginids) {

        try {
            my $user = BOM::User->new(loginid => $updated_loginid->[0]);

            my $main_acc;

            foreach my $loginid ($user->loginids) {
                if ($loginid =~ /^CR|VRTC$/) {
                    $main_acc = $loginid;
                    last;
                }
            }

            my $client = BOM::User::Client->new({loginid => $main_acc});

            my $rule_engine = BOM::Rules::Engine->new(client => $client);

            my $dx = BOM::TradingPlatform->new(
                rule_engine => $rule_engine,
                platform    => 'dxtrade',
                client      => $client
            );

            $dx->call_api(
                server        => $account_type,
                method        => 'account_category_set',
                clearing_code => DX_CLEARING_CODE,
                account_code  => $updated_loginid->[0],
                category_code => "Trading",
                value         => "CFD",
            );
        } catch ($e) {
            $log->errorf("An error has occured while processing %s : %s", $updated_loginid->[0], $e);
            return;
        };

    }

    $log->infof("Done fetching and updating DerivX %s %s accounts.", $account_type, $market_type);
}

get_dx_financial_accounts();
