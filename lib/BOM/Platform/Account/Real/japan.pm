package BOM::Platform::Account::Real::japan;

use strict;
use warnings;

use JSON qw(encode_json);
use BOM::Platform::Account::Real::default;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Email qw(send_email);

sub validate {
    my $args  = shift;
    my $check = BOM::Platform::Account::Real::default::validate($args);
    return $check if ($check->{err});

    #TODO: until we set JP <> restricted country
    return $check;
#    return $check if ($from_client->residence eq 'jp');

    return {err => 'Account opening unavailable'};
}

sub create_account {
    my $args = shift;
    my ($user, $details, $financial_data) = @{$args}{'user', 'details', 'financial_data'};

    my $daily_loss_limit = delete $details->{daily_loss_limit};

    my $acc  = BOM::Platform::Account::Real::default::create_account({
        user    => $user,
        details => $details,
    });
    return $acc if ($acc->{err});

    my $client = $acc->{client};
    $client->financial_assessment({
        data => encode_json($financial_data),
    });
    $client->set_exclusion->max_losses($daily_loss_limit);
    $client->save;

    return $acc;
}

1;
