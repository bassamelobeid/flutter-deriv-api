package BOM::MyAffiliates::TurnoverReporter;

=head1 NAME

BOM::MyAffiliates::TurnoverReporter

=head1 DESCRIPTION

This class generates turnover report for clients.

It includes contract buy price, payout price, probability
and contract reference id

=head1 SYNOPSIS

    use BOM::MyAffiliates::TurnoverReporter;

    my $reporter = BOM::MyAffiliates::TurnoverReporter->new(
        brand           => Brands->new(),
        processing_date => Date::Utility->new('18-Aug-10'));

    $reporter->activity();

=cut

use Moose;
extends 'BOM::MyAffiliates::Reporter';

use Date::Utility;
use Text::CSV;
use File::SortedSeek qw/numeric get_between/;
use Format::Util::Numbers qw/financialrounding/;

use constant HEADERS => qw(
    Date Loginid Stake PayoutPrice Probability ReferenceId
);

=head2 activity

    $reporter->activity();

    Produce a nicely formatted CSV output adjusted into USD
    for the requested date formatted as follows:

    Transaction date, Client loginid, Buy price (stake), payout price,
    probablity (stake/payout_price*100), contract reference id

=cut

sub activity {
    my $self = shift;

    my $apps_by_brand = $self->get_apps_by_brand();
    my $activity      = $self->database_mapper()->get_trading_activity({
        date         => $self->processing_date->date_yyyymmdd,
        include_apps => $apps_by_brand->{include_apps},
        exclude_apps => $apps_by_brand->{exclude_apps},
    });

    my @output = ();
    push @output, $self->format_data($self->headers_data()) if ($self->include_headers and scalar @$activity);

    foreach my $obj (@$activity) {
        my $loginid = $obj->[1];

        next if $self->is_broker_code_excluded($loginid);

        my $csv           = Text::CSV->new;
        my @output_fields = (
            # transaction date
            Date::Utility->new($obj->[0])->date_yyyymmdd,
            # loginid
            $self->prefix_field($loginid),
            # stake
            financialrounding('price', 'USD', $obj->[2]),
            # payout
            financialrounding('price', 'USD', $obj->[3]),
            # probability
            $obj->[4],
            # contract reference id
            $obj->[5]);
        $csv->combine(@output_fields);
        push @output, $self->format_data($csv->string);
    }

    return @output;
}

sub output_file_prefix {
    return 'turnover_';
}

sub headers {
    return HEADERS;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
