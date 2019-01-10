use strict;
use warnings;

use Test::More;
use BOM::User::FinancialAssessment;
use BOM::Config;

my @financial_information_keys = qw/
    occupation
    education_level
    source_of_wealth
    estimated_worth
    account_turnover
    employment_industry
    income_source
    net_income
    employment_status/;

my @trading_experience_keys = qw/
    other_instruments_trading_frequency
    other_instruments_trading_experience
    binary_options_trading_frequency
    binary_options_trading_experience
    forex_trading_frequency
    forex_trading_experience
    cfd_trading_frequency
    cfd_trading_experience/;

my $input_mapping = BOM::Config::financial_assessment_fields();

subtest "check for all keys" => sub {
    is_deeply([sort keys %{$input_mapping->{financial_information}}], [sort @financial_information_keys], 'correct keys for financial information');
    is_deeply([sort keys %{$input_mapping->{trading_experience}}],    [sort @trading_experience_keys],    'correct keys for trading experience');
};

subtest "check if keys are valid" => sub {
    foreach my $key (@financial_information_keys) {
        ok exists $input_mapping->{financial_information}->{$key}->{label},           "label key exists for $key in financial_information";
        ok exists $input_mapping->{financial_information}->{$key}->{possible_answer}, "possible_answer key exists for $key in financial_information";
    }

    foreach my $key (@trading_experience_keys) {
        ok exists $input_mapping->{trading_experience}->{$key}->{label},           "label key exists for $key in trading_experience";
        ok exists $input_mapping->{trading_experience}->{$key}->{possible_answer}, "possible_answer key exists for $key in trading_experience";
    }
};

subtest "check total score is 71" => sub {
    my $total_score = 0;

    foreach my $key (@financial_information_keys) {
        my $answer_hash = $input_mapping->{financial_information}->{$key}->{possible_answer};
        foreach my $answer (keys %{$answer_hash}) {
            $total_score += $answer_hash->{$answer};
        }
    }

    foreach my $key (@trading_experience_keys) {
        my $answer_hash = $input_mapping->{trading_experience}->{$key}->{possible_answer};
        foreach my $answer (keys %{$answer_hash}) {
            $total_score += $answer_hash->{$answer};
        }
    }
    is($total_score, 71, "total score is 71");
};

done_testing;
