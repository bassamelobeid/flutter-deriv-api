package BOM::User::Script::IDVCheckLogEvictioner;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::User::Script::IDVCheckLogEvictioner - Evictions old `idv.document_check_log` partitions.

=head1 SYNOPSIS

    BOM::User::Script::IDVCheckLogEvictioner::run;

=head1 DESCRIPTION

This module is used by the `idv_check_log_evictioner.pl` script. Meant to provide a testable
collection of subroutines.

Meant to be run as a monthly cronjob. The retain period is 2 years.

=cut

use BOM::Database::UserDB;
use Date::Utility;
use BOM::Config;

=head2 run

Evicts up to 12 partitions older than 2 years.

Returns C<undef>

=cut

sub run {
    my $user_db = BOM::Database::UserDB::rose_db()->dbic;
    my $base    = Date::Utility->new()->minus_time_interval('2y');

    for (1 .. 12) {
        $base = $base->minus_months(1);

        $user_db->run(
            fixup => sub {
                $_->do("SELECT idv.drop_document_check_log_partition (?::TIMESTAMP)", undef, $base->date_yyyymmdd);
            });
    }
}

1;
