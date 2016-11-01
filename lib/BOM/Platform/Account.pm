package BOM::Platform::Account;

use strict;
use warnings;

use BOM::Database::Rose::DB::StringifyRules;

# TODO: to be removed later
# Temporary only allow Japan with @binary.com email
sub invalid_japan_access_check {
    my $residence = shift // '';
    my $email     = shift // '';

    if ($residence eq 'jp' and $email !~ /\@binary\.com$/) {
        die "NOT authorized JAPAN access: $residence , $email";
    }
}

1;
