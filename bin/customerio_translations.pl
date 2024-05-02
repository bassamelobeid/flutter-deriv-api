#!/etc/rmg/bin/perl
use strict;
use warnings;

use Getopt::Long;
use BOM::Backoffice::Script::CustomerIOTranslation;
use Log::Any::Adapter;
use Log::Any qw($log);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

=head1 customerio_email_snippets.pl

This script will update campaigns and snippets on customer.io.

=cut

GetOptions(
    'l|log=s'      => \my $log_level,
    't|token=s'    => \my $token,
    'c|campaign=s' => \my $filter_campaign,
);

Log::Any::Adapter->import('DERIV', log_level => $log_level // 'info');

my @tokens;
push @tokens, $token if $token;
push @tokens, split(/\s*?,\s*?/, $ENV{CUSTOMERIO_TOKENS_QA})   if $ENV{CUSTOMERIO_TOKENS_QA};
push @tokens, split(/\s*?,\s*?/, $ENV{CUSTOMERIO_TOKENS_REAL}) if $ENV{CUSTOMERIO_TOKENS_REAL};

die "token is required\n" unless @tokens;

BOM::Backoffice::Script::CustomerIOTranslation::update_all_envs_and_email_warnings(\@tokens, $filter_campaign);
