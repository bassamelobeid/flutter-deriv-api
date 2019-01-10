package BOM::Test::Helper::FinancialAssessment;

use warnings;
use strict;

use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::User::FinancialAssessment;

sub _get_by_index {
    my $h = shift;
    return (sort { $h->{$a} <=> $h->{$b} || $a cmp $b } keys %$h)[shift];

}
my $first = sub {
    return (sort keys %{$_[0]})[0];
};
my $min = sub { return _get_by_index($_[0], 0) };
my $max = sub { return _get_by_index($_[0], -1) };
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
    my $type = shift // 'first';
    die "Types can be: ", join ', ', (keys %$types) unless defined $types->{$type};
    return _get_with_selector($types->{$type});
}

sub _get_with_selector {
    my $func = shift;
    my $h    = BOM::Config::financial_assessment_fields();
    my %r    = map {
        my $inner = $_;
        map { $_ => $func->($inner->{$_}->{possible_answer}) } keys %$inner
    } values %$h;

    return \%r;
}

sub mock_maltainvest_fa {
    my %data = (
        "forex_trading_experience"             => "Over 3 years",                                     # +2
        "forex_trading_frequency"              => "0-5 transactions in the past 12 months",           # +0
        "binary_options_trading_experience"    => "1-2 years",                                        # +1
        "binary_options_trading_frequency"     => "40 transactions or more in the past 12 months",    # +2
        "cfd_trading_experience"               => "1-2 years",                                        # +1
        "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",           # +0
        "other_instruments_trading_experience" => "Over 3 years",                                     # +2
        "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",          # +1
        "employment_industry"                  => "Finance",                                          # +15
        "education_level"                      => "Secondary",                                        # +1
        "income_source"                        => "Self-Employed",                                    # +0
        "net_income"                           => '$25,000 - $50,000',                                # +1
        "estimated_worth"                      => '$100,000 - $250,000',                              # +1
        "occupation"                           => 'Managers',                                         # +0
        "employment_status"                    => "Self-Employed",                                    # +0
        "source_of_wealth"                     => "Company Ownership",                                # +0
        "account_turnover"                     => 'Less than $25,000',                                # +0
    );

    return encode_json_utf8(\%data);
}

1;
