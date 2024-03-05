package BOM::Test::Helper::FinancialAssessment;

use warnings;
use strict;

use JSON::MaybeUTF8 qw(encode_json_utf8);
use Business::Config;

sub _get_by_index {
    my $h = shift;
    return (sort { $h->{$a} <=> $h->{$b} || $a cmp $b } keys %$h)[shift];

}
my $first = sub {
    return (sort keys %{$_[0]})[0];
};
my $min   = sub { return _get_by_index($_[0], 0) };
my $max   = sub { return _get_by_index($_[0], -1) };
my $types = {
    'first' => $first,
    'min'   => $min,
    'max'   => $max,
};

=head2 get_fulfilled_hash

    returns hash of all questions inside financial assesements with answers.
    Answer selection is controlled by optional argument:
    - first (default) - first from sorted list of names
    - min - element with minimum weight, first from sorted list
    - max - element with maximum weight, last in sorted list

=cut

sub get_fulfilled_hash {
    my $type = shift // 'max';
    die "Types can be: ", join ', ', (keys %$types) unless defined $types->{$type};
    return _get_with_selector($types->{$type});
}

sub _get_with_selector {
    my $func = shift;
    my $h    = Business::Config->new()->financial_assessment();
    my %r    = map {
        my $inner = $_;
        map { $_ => $func->($inner->{$_}->{possible_answer}) } keys %$inner
    } values %$h;

    return \%r;
}

sub mock_maltainvest_fa {
    my $raw  = shift;
    my %data = (
        "risk_tolerance"                           => "Yes",
        "source_of_experience"                     => "I have an academic degree, professional certification, and/or work experience.",
        "cfd_experience"                           => "Less than a year",
        "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
        "trading_experience_financial_instruments" => "Less than a year",
        "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
        "cfd_trading_definition"                   => "Speculate on the price movement.",
        "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
        "leverage_trading_high_risk_stop_loss"     => "Close your trade automatically when the loss is more than or equal to a specific amount.",
        "required_initial_margin"                  => "When opening a Leveraged CFD trade.",
        "employment_industry"                      => "Finance",
        "education_level"                          => "Secondary",
        "income_source"                            => "Self-Employed",
        "net_income"                               => '$25,000 - $50,000',
        "estimated_worth"                          => '$100,000 - $250,000',
        "occupation"                               => 'Managers',
        "employment_status"                        => "Self-Employed",
        "source_of_wealth"                         => "Company Ownership",
        "account_turnover"                         => 'Less than $25,000',
        "account_opening_reason"                   => "Speculative",
    );
    return \%data if $raw;
    return encode_json_utf8(\%data);
}

sub mock_maltainvest_set_fa {
    my $data = {
        "trading_experience_regulated" => {
            "risk_tolerance"                           => "Yes",
            "source_of_experience"                     => "I have an academic degree, professional certification, and/or work experience.",
            "cfd_experience"                           => "Less than a year",
            "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
            "trading_experience_financial_instruments" => "Less than a year",
            "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
            "cfd_trading_definition"                   => "Speculate on the price movement.",
            "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
            "leverage_trading_high_risk_stop_loss"     => "Close your trade automatically when the loss is more than or equal to a specific amount.",
            "required_initial_margin"                  => "When opening a Leveraged CFD trade.",
        },
        "financial_information" => {
            "employment_industry" => "Finance",
            "education_level"     => "Secondary",
            "income_source"       => "Self-Employed",
            "net_income"          => '$25,000 - $50,000',
            "estimated_worth"     => '$100,000 - $250,000',
            "occupation"          => 'Managers',
            "employment_status"   => "Self-Employed",
            "source_of_wealth"    => "Company Ownership",
            "account_turnover"    => 'Less than $25,000',
        }};
    return $data;
}

1;
