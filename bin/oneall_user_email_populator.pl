#!/usr/bin/perl

use strict;
use warnings;

use BOM::Config;
use BOM::Database::Model::UserConnect;

use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => 'info';
use Syntax::Keyword::Try;

=head1 NAME oneall_user_email_populator.pl

It's a temporary script that extracts email from provider data and populate it to the same row in batches

Will be tracked and removed in https://app.clickup.com/t/20696747/PLA-456
    
=cut

my $user_connect = BOM::Database::Model::UserConnect->new;

my $max_iteration = 2000;
my $i             = 0;

my $errors         = 0;
my $should_proceed = 1;

while ($should_proceed) {
    my $result;
    try {
        $result = $user_connect->dbic->run(
            ping => sub {
                $_->do("
                UPDATE users.binary_user_connects a
                   SET email = b.provider_data->'user'->'identity'->'emails'->0->>'value'
                  FROM (
                        SELECT id, provider_data FROM users.binary_user_connects
                         WHERE email IS NULL
                           AND provider_data::TEXT <> '{}'
                         LIMIT 3000
                    ) b
                 WHERE a.id = b.id
            ");
            });

        $i++;

        sleep 7;
    } catch ($e) {
        $log->errorf('An error occurred during populating OneAll emails to user connects information, error: %s', $e);
        $errors++;
    }

    $should_proceed = 0 if $result < 1 or $errors > 3 or $i >= $max_iteration;
}
