package BOM::MarketDataAutoUpdater;

use Moose;
use Date::Utility;
use BOM::Platform::Runtime;
use Email::Stuffer;
use Cache::RedisDB;

use constant MIN_TIME_BETWEEN_EMAILS => 3600;

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

    return 1 if ($self->is_a_weekend);    # don't do anything on weekend

    my $market              = ref $self;
    my @keys_in_redis       = ('QUANT_EMAIL', 'vol_' . $market);
    my $vol_email_frequency = Cache::RedisDB->get(@keys_in_redis);

    if (not $vol_email_frequency) {
        Cache::RedisDB->set_nw(@keys_in_redis, time);
        $vol_email_frequency = time;
    }

    return if time - $vol_email_frequency <= MIN_TIME_BETWEEN_EMAILS;    #too early to send email for this market

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
    my $number_failures = scalar @failures - 1;
    my $number_errors   = scalar @errors - 1;

    if ($failures > 0 or $number_errors > 0) {
        Cache::RedisDB->set_nw(@keys_in_redis, time);

        my $body = join "\n", (@successes, "\n\n", @failures, "\n\n", @errors);
        my $subject_line = $market . ' failed. Number of failures is ' . $number_failures . '. Number of errors is ' . $number_errors . '.';

        return Email::Stuffer->from('system@binary.com')->to('quants-market-data@binary.com')->subject($subject_line)->text_body($body)->send_or_die;
    }
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
