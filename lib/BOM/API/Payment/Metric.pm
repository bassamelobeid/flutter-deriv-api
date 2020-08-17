package BOM::API::Payment::Metric;

use strict;
use warnings;
use DataDog::DogStatsd::Helper qw(stats_inc);

=head2 collect_success_failure_metric

Contains the logic to collect success/failure metrics.

=cut

sub collect_success_failure_metric {
    my ($metric_name, $status_code, $tags) = @_;

    # DoughFlow accepts 0 as success, and 2xx is for successful HTTP status code.
    if ($status_code =~ /^(0|2)/) {
        DataDog::DogStatsd::Helper::stats_inc("$metric_name.success", {tags => $tags});
    } elsif ($status_code =~ /^(4|5)/) {
        DataDog::DogStatsd::Helper::stats_inc("$metric_name.failure", {tags => $tags});
    }
}

=head2 collect_metric

Function to capture our metrics.

=cut

sub collect_metric {
    my ($type, $response, $tags) = @_;
    my $metric_name = "bom.paymentapi.doughflow.$type";

    if (exists($response->{status})) {
        collect_success_failure_metric($metric_name, $response->{status}, $tags);
    } elsif (exists($response->{status_code})) {
        collect_success_failure_metric($metric_name, $response->{status_code}, $tags);
    } else {
        # Handles validation type (such as deposit_validate_GET and withdrawal_validate_GET)
        # when request is successful.
        if ($type =~ /validate/) {
            if ($response->{'allowed'}) {
                DataDog::DogStatsd::Helper::stats_inc("$metric_name.approve", {tags => $tags});
            } else {
                DataDog::DogStatsd::Helper::stats_inc("$metric_name.reject", {tags => $tags});
            }
        }
    }
}

1;
