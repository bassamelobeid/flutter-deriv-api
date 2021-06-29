use strict;
use warnings;

use Test::Deep;
use Test::More;
use Test::MockModule;

use BOM::Platform::Utility;

subtest 'hash_to_array' => sub {
    subtest 'simple hash' => sub {
        my $input = {
            a => '1',
            b => {
                c => '2',
                d => '3',
            },
        };

        my @expected_output = ('1', '2', '3');
        my $output          = BOM::Platform::Utility::hash_to_array($input);

        cmp_bag $output, \@expected_output, "simple hash is OK";
    };

    subtest 'simple hash of arrays' => sub {
        my $input = {
            a => ['1', '2', '3'],
            b => {
                c => ['4', '5', '6'],
                d => ['7', '8', '9'],
            },
        };

        my @expected_output = ('1', '2', '3', '4', '5', '6', '7', '8', '9');
        my $output          = BOM::Platform::Utility::hash_to_array($input);

        cmp_bag $output, \@expected_output, "simple hash of arrays is OK";
    };

    subtest 'complex hash' => sub {
        my $input = {
            # hash of array
            a => ['1', '2', '3'],
            # nested hash of arrays
            b => {
                a => ['x', 'y', 'z'],    # redundant key 'a'
                c => ['4', '5', '6'],
                d => ['7', '8', '9'],
            },
            # hash of array of hashes
            z => [{
                    x => ['f'],
                    y => ['g'],
                }
            ],
            # simple hash
            q => 't',
        };

        my @expected_output = ('1', '2', '3', '4', '5', '6', '7', '8', '9', 'f', 'g', 't', 'x', 'y', 'z');
        my $output          = BOM::Platform::Utility::hash_to_array($input);

        cmp_bag $output, \@expected_output, "complex hash is OK";
    };
};

subtest 'extract_valid_params' => sub {
    my $args = {
        utm_content      => '$content',
        utm_campaign     => 'campaign$',
        utm_term         => 'te$rm',
        utm_campaign_id  => 111017190001,
        utm_ad_id        => 'f521708e-db6e-478b-9731-8243a692c2d5',
        utm_adgroup_id   => 45637,
        utm_gl_client_id => 3541,
        utm_msclk_id     => 5,
        utm_fbcl_id      => 6,
        utm_adrollclk_id => 7,
        pa_amount        => 20,
        pa_loginid       => 'CR9000000%1',
        pa_currency      => 'U',
        pa_remarks       => 'Remarks'
    };
    my $params                = [keys $args->%*];
    my $regex_validation_keys = {
        qr{^utm_.+}     => qr{^[\w\s\.\-_]{1,100}$},
        qr{pa_currency} => qr{^[a-zA-Z0-9]{2,20}$},
        qr{pa_loginid}  => qr{^[A-Za-z]+[0-9]+$},
    };
    my $result = BOM::Platform::Utility::extract_valid_params($params, $args, $regex_validation_keys);

    subtest 'matching arguments validation' => sub {
        foreach my $key (keys $regex_validation_keys->%*) {
            foreach my $arg (keys $args->%*) {
                if ($arg =~ /$key/) {
                    is $result->{$arg}, $args->{$arg}, 'argument has been validated correctly' if $args->{$arg} =~ /$regex_validation_keys->{$key}/;
                    is $result->{$arg}, undef, 'argument has been discarded as expected' if $args->{$arg} !~ /$regex_validation_keys->{$key}/;
                }
            }
        }
    };

    subtest 'unmatched arguments validation' => sub {
        my $all_keys_regex   = join '|', keys $regex_validation_keys->%*;
        my @args_to_validate = grep { $_ !~ /$all_keys_regex/ } keys $args->%*;

        foreach my $arg (@args_to_validate) {
            is $result->{$arg}, $args->{$arg}, 'argument has been returned as expected';
        }
    };

};

done_testing;
