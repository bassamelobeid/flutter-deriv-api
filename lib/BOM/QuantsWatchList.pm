package BOM::QuantsWatchList;

use strict;
use warnings;

use BOM::Platform::Runtime;

sub get_watchlist {
    return BOM::Platform::Runtime->instance->app_config->quants->internal->watchlist;
}

sub get_details_for {
    my $client_loginid = shift;

    return get_watchlist->{$client_loginid} // '';
}

sub update_details_for {
    my ($client_loginid, $comment, $commented_by) = @_;

    # two types of update:
    # 1. delete where $comment is an empty string
    # 2. add client to watchlist with $comment
    my $current = get_watchlist();

    if ($comment) {
        $current->{$client_loginid} = $comment . ', updated by ' . $commented_by; # override
    } elsif (exists $current->{$client_loginid}) {
        delete $current->{$client_loginid};
    }

    BOM::Platform::Runtime->instance->app_config->quants->internal->watchlist($current);
    return BOM::Platform::Runtime->instance->app_config->save_dynamic;
}

1;
