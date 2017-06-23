use strict;
use warnings;

use Test::More;
use BOM::Platform::Account::Real::default;

my @all_keys =
    qw/other_derivatives_trading_frequency stocks_trading_experience other_instruments_trading_frequency stocks_trading_frequency forex_trading_frequency education_level other_derivatives_trading_experience forex_trading_experience commodities_trading_frequency employment_industry income_source indices_trading_frequency commodities_trading_experience other_instruments_trading_experience occupation indices_trading_experience estimated_worth account_turnover net_income/;

my $input_mapping = BOM::Platform::Account::Real::default::get_financial_input_mapping();

subtest "check for all keys" => sub {
    is_deeply([sort keys %{$input_mapping}], [sort @all_keys], 'correct keys for financial input mapping');
};

subtest "check if keys are valid" => sub {
    foreach my $key (@all_keys) {
        ok exists $input_mapping->{$key}->{label},           "label key exists for $key";
        ok exists $input_mapping->{$key}->{possible_answer}, "possible_answer key exists for $key";
    }
};

subtest "check total score is less than or equal to 60" => sub {
    my $total_score = 0;
    foreach my $key (@all_keys) {
        my $answer_hash = $input_mapping->{$key}->{possible_answer};
        foreach my $score (sort { $answer_hash->{$b} <=> $answer_hash->{$a} } keys %$answer_hash) {
            $total_score += $answer_hash->{$score};
            last;
        }
    }
    cmp_ok($total_score, '<=', 60, "total score should be less than equal to 60");
};

done_testing;
