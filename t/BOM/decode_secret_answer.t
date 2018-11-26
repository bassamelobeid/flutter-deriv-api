use strict;
use warnings;

use Test::More;
use Text::CSV;
use Test::Warnings qw/warning/;
use Test::Exception;
use Test::MockModule;

use utf8;
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use Crypt::CBC;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';
use Encode;
use Encode::Detect::Detector;

use BOM::User::Utility;

my @blowfish_encoded_answers = (
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4',
    '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4', '::ecp::52616e646f6d495633363368676674795cdef637d0ee49d4'
);

my @other_encoded_answers = (
    '1*U2FsdGVkX189SoigLGPEZGtIIk1Xtdd98iEkWuVeOcxXAEeRIef4rn7b7CLEWjUDMxnSa+bb7l/i3ljHv1o27zfz+DjuOISUS5u9/Q9QO1s',
    '1*U2FsdGVkX1/oIKD7KBGr5dWtVV6whB/KhETNlpoxFmi7GwSL9AuyK43YCMPx4o44yNvYV4DLYk7guD4diIsw+dgFYfvBvH7Vlp/GtV3VjkQ',
    '1*U2FsdGVkX18awRKLA41d/IayVds6V1L3oVwLZebv8X5KevEshNHfBqSofHD2f8z848rtFuOjBA3aEI9FNWtnjGWmYceNhReNUfFWbWcS5JU',
    '1*U2FsdGVkX1/lp4J7n3GyvuZsvnzrj4X1duqt1Qmip00ItGCcrAoA3hiCM2I8dAYuqBgBIlonArIX6uU/IN1cT+Ar+koueVOvNF6ay7Vvnpc',
    '1*U2FsdGVkX1+X/qX1KcbHO5HQ491eUTl2veoZDEgE9f2geQO1rQm+9LL5ndvQW54RFGUBCCtd+IvdsbFMsG4TGdGAmzY7pFrrDZRSvR3tDvc',
    '1*U2FsdGVkX1/89pTs1OtQA/t9vntCek0k4LtiPK2TNz1xmHKfNjJNtNJMv7zFV920H0laBu+QlmhwYhVf3Nkzu/ewG2trDTCmt9GsQKx/9LI',
    '1*U2FsdGVkX19FLobEXM7+DpCYEymqisMTenT5LqNch5yoc+5n1d12OfKL4ySaxIpOCZXkQ/AmLQ/2S1PtXmnx5Oi8NIu1GSa7yB+PEW5JvOw',
    '1*U2FsdGVkX19yDIW+/fF5puQdLGJ6eBmDqBrJIT+Drod6LcSb5obyQlX8BqvieSQV4n1flEvGuXuRNgeQVl3gtzO/lEuEHxK2iISHbZEZ6VA',
    '1*U2FsdGVkX194dY3GElohAezkkeS58rpjC92nD3P/aCp3wBKKUx2JP4ZnV9GVYEAYQrcb4gfBrto4SuS3o30zeongEPv7VM1HNtttTMF0aKs',
    '1*U2FsdGVkX1/tIy/yVVpq0IR0+nQSBJqwzjMHELPwHMbCLMHeJIpv35qjeqL/VTZlbHLm2T2TY0E4cMh8814MuR3IRYtLCPUXwVQtFnyyZ3A',
    '1*U2FsdGVkX1+vG2nU25d5guakY3kTypiIx1exAaw5bLpgaEQ8lls4K0hU7xX8RbWmEzWISzaTn79lNmeJFK+QgkGQgGcwX9ET7O+wLbmzNjQ',
    '1*U2FsdGVkX1+Yu9L/5aB/S0pIyF4BKQELsI0N/XXCiiWFSzWPzznv7hd+ONqGYsNIfQwOsd+o2p98RbDPQ8uUOXBpMtApUH2KTsbcJRqEVTU',
    '1*U2FsdGVkX18P8MDOIrbeu1Msyd8m13uX/8zJCcVRuipRaHDsRiZzij94nt6aDkFkUSxZ2Kqu83PDY81OVymnNUtNFLI0OOozp2dr6NNW+2k',
    '1*U2FsdGVkX18pCXQmy32+RQC9NIJBO6+RnodksPwJROaVH9PwfiqBzklr3tT1trOF6Z4cl9hoquGf4yk7GgpglHMgfvGxgzNy9OiPLwL49+U',
    '1*U2FsdGVkX19hYqvf+aHV+Jhh6QG4sikAWed62TwqJjmO9wU0DrS/uJVdn8wObIRN2LxcwpUN1gdX2CimPa10IpLTTlVtljDP7vptFoNemGg',
    '1*U2FsdGVkX18IKNLBDRSKHrfYG9v71rvs1cJ1JW++zAh3A796vV0q/B3lo3VHosd7r4phiK0slYmERs7yAIGKNVqY/VLZ0WRbQoxRyI7lvW0',
    '1*U2FsdGVkX18e/J7oNfPpvt3o3XXu0RO5Pbspnwu4btCYpSn6zOSTaSkpWqV6fZ3DFfXL8UOnDF85oMKZNF61TLyUPYy/vRzGiPs7wMRyS1Y',
);

subtest 'previous functionality' => sub {
    my $module = Test::MockModule->new('BOM::User::Utility');
    $module->mock(
        'decrypt_secret_answer',
        sub {
            my $secret_answer = shift;
            if ($secret_answer =~ /^\w+\*.*\./) {    # new AES format
                return Crypt::NamedKeys->new(keyname => 'client_secret_answer')->decrypt_payload(value => $secret_answer);
            } elsif ($secret_answer =~ s/^::ecp::(\S+)$/$1/) {    # legacy blowfish
                my $cipher = Crypt::CBC->new({
                    'key'    => '1nsceaag3g3',
                    'cipher' => 'Blowfish',
                    'iv'     => '252gfesv',
                    'header' => 'randomiv',
                });

                $secret_answer = $cipher->decrypt_hex($secret_answer);

                if (Encode::Detect::Detector::detect($secret_answer) eq 'UTF-8') {
                    return Encode::decode('UTF-8', $secret_answer);
                } else {
                    return $secret_answer;
                }
            } else {
                return $secret_answer;
            }
        });

    foreach my $answer (@blowfish_encoded_answers) {
        like(
            warning { BOM::User::Utility::decrypt_secret_answer($answer) },
            qr/Use of uninitialized value in string eq at/,
            'blowfish corrupted answer generate warnings'
        );
    }

    foreach my $answer (@other_encoded_answers) {
        lives_ok(sub { BOM::User::Utility::decrypt_secret_answer($answer) }, "Even faulty input don't die");
    }

    $module->unmock_all();
};

subtest 'current functionality' => sub {
    foreach my $answer (@other_encoded_answers) {
        throws_ok { BOM::User::Utility::decrypt_secret_answer($answer) } qr/Not able to decode secret answer! Invalid or outdated encrypted value./,
            'corrupted answer throw decode exception';
    }

    is BOM::User::Utility::decrypt_secret_answer(''), undef, 'empty encoded answer will return undef';
};

done_testing();
