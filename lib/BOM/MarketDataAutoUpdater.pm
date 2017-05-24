package BOM::MarketDataAutoUpdater;

use Moose;
use Date::Utility;
use BOM::Platform::Runtime;
use Email::Stuffer;
use Cache::RedisDB;

has report => (
    is      => 'rw',
    default => sub { {} },
);

has is_a_weekend => (
    is      => 'ro',
    default => sub { Date::Utility->new->is_a_weekend },
);

sub run {
    my $self = shift;

    my $vol_email_frequency = Cache::RedisDB->get('QUANT_EMAIL', 'FOREX_VOL');

    if (not $vol_email_frequency) {
        Cache::RedisDB->set_nw('QUANT_EMAIL', 'FOREX_VOL', time);
        $vol_email_frequency = time;
    }

    return 1 if ($self->is_a_weekend);    # don't do anything on weekend
    my $report    = $self->report;
    my @successes = ('SUCCESSES');
    my @failures  = ('FAILURES');
    my @errors    = ('ERRORS');
    foreach my $symbol (sort keys %$report) {
        if ($symbol eq 'error') {
            push @errors, @{$report->{$symbol}};
        } else {
            my $status = $report->{$symbol}->{success};
            if ($status) {
                push @successes, $symbol;
            } else {
                push @failures, "$symbol failed, reason: $report->{$symbol}->{reason}";
            }
        }
    }
    my $number_failures  = scalar @failures - 1;
    my $error            = scalar @errors - 1;
    push @successes, "\n\n";
    push @failures,  "\n\n";

    my $time_from_last_email = time - $vol_email_frequency;
    if (($number_failures > 0 or $error > 0) and $time_from_last_email > 3600) {
        Cache::RedisDB->set_nw('QUANT_EMAIL', 'FOREX_VOL', time);

        my $body = join "\n", (@successes, @failures, @errors);
        my $subject_line = ref $self;
        $subject_line .= ' failed. Number of failures is ' . $number_failures . '. Number of errors is ' . $error . '.';

        return Email::Stuffer->from('system@binary.com')->to('quants-market-data@binary.com')->subject($subject_line)->text_body($body)->send_or_die;
    }
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
