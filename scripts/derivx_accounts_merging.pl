#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::TradingPlatform::DXAccountsMerging;
use IO::Async::Loop;
use Future::AsyncAwait;
use Pod::Usage;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'info';
use Getopt::Long;

=head1 NAME

derivx_accounts_merging.pl

=head1 SYNOPSIS

./derivx_accounts_merging.pl [options] 

=head1 NOTE

This script will transfer balance from financial to synthetic accounts (real only) and
change financial accounts' statuses ('archived' in our DB and 'TERMINATED' in DerivX) 

=head1 OPTIONS

=over 20

=item B<-h>, B<--help>

Brief help message

=item B<-a>, B<--account_type>

MT5 server type ('real' or 'demo')

=item B<-f>, B<--file>

File with failed deposits to process

=item B<-s>, B<--status_filter>

Status filter for the SQL query (default: 1)

=back

=cut

my $help                 = 0;
my $account_type         = 'demo';
my $failed_deposits_file = '';
my $status_filter        = 1;

GetOptions(
    'a|account_type=s'         => \$account_type,
    'f|failed_deposits_file=s' => \$failed_deposits_file,
    's|status_filter=i'        => \$status_filter,
    'h|help!'                  => \$help,
);

pod2usage(1) if $help;

my $accounts_merging = BOM::TradingPlatform::DXAccountsMerging->new(
    account_type         => $account_type,
    status_filter        => $status_filter,
    failed_deposits_file => $failed_deposits_file,
);

$accounts_merging->accounts_merging;

1;
