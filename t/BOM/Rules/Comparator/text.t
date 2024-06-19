use strict;
use warnings;
use utf8;

use Test::More;
use BOM::Rules::Comparator::Text;

subtest 'check words similarity' => sub {
    my $cases = [{
            act    => 'Felipe Martinez',
            exp    => 'Felipe Martínez',
            result => 1,
        },
        {
            act    => 'Felipe Martinez',
            exp    => 'Felipe Martinez',
            result => 1,
        },
        {
            act    => 'Felipe Martínez',
            exp    => 'Felipe Martínez',
            result => 1,
        },
        {
            act    => 'Çapybara Mágica',
            exp    => 'Magica Capybara',
            result => 1,
        },
        {
            act    => 'This is too easy',
            exp    => 'this is too Easy',
            result => 1,
        },
        {
            act    => 'this is a choppy test',
            exp    => 'this choppy is a test',
            result => 1,
        },
        {
            act    => 'Nguyen long',
            exp    => 'NGUYEN XUAN LONG',
            result => 1,
        },
        {
            act    => 'Ngyen long',
            exp    => 'NGUYEN XUAN LONG',
            result => 0,
        },
        {
            act    => 'aNguyen long',
            exp    => 'NGUYEN XUAN LONG',
            result => 0,
        },
        {
            act    => 'aNgyen long',
            exp    => 'NGUYEN XUAN LONG',
            result => 0,
        },
        {
            act    => 'nguyen juan long',
            exp    => 'NGUYEN XUAN LONG',
            result => 0,
        },
        {
            act    => 'nguyen xuan long',
            exp    => 'NGUYEN XUAN LONG',
            result => 1,
        },
        {
            act    => 'nguyen xuan loong',
            exp    => 'NGUYEN XUAN LONG',
            result => 0,
        },
        {
            act    => 'homero simpson',
            exp    => 'homer simpson',
            result => 0,
        },
        {
            act    => '',
            exp    => 'void',
            result => 0,
        },
        {
            act    => 'void',
            exp    => '',
            result => 0,
        },
        {
            act    => 'Иван',
            exp    => 'Ivan',
            result => 1,
        },
        {
            act    => 'χρονος',
            exp    => 'khronos',
            result => 1,
        }];

    for my $case ($cases->@*) {
        is BOM::Rules::Comparator::Text::check_words_similarity($case->{act}, $case->{exp}), $case->{result}, "Expected result for test case";
    }
};

done_testing();
