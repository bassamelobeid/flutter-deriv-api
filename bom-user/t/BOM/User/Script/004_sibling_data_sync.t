use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use File::Temp   qw/ tempfile tempdir /;
use Text::CSV_XS qw( csv );
use Data::Random qw(:all);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Script::SiblingDataSync;
use BOM::User;
use BOM::User::Client;

subtest 'Sibling Data Sync Script' => sub {
    my $exception;

    my $args = {
        dry_run => 1,
    };

    my @all_fields = qw(account_opening_reason tax_identification_number tax_residence);

    subtest 'Input Validation' => sub {
        $exception = exception { ok !BOM::User::Script::SiblingDataSync->run($args); };
        ok $exception =~ /file_path is mandatory/, 'file_path is mandatory';

        $args->{file_path} = 'test_file_path.csv';

        $exception = exception { ok !BOM::User::Script::SiblingDataSync->run($args); };
        ok $exception =~ /$args->{file_path}: No such file or directory/, 'Valid file path';

        # Create a temporary file
        my ($fh, $filename) = tempfile(SUFFIX => ".csv");
        $args->{file_path} = $filename;
        $exception = exception { ok !BOM::User::Script::SiblingDataSync->run($args); };
        ok $exception =~ /Empty or invalid CSV file/, 'Empty CSV';
        print $fh "header1,header2\n";
        print $fh "value1,value2\n";
        # Close the filehandle so the file gets written
        close $fh;

        $args->{fields_ref} = [];
        $exception = exception { ok !BOM::User::Script::SiblingDataSync->run($args); };
        ok $exception =~ /One or more given fields are invalid./, 'Valid fields';

        $args->{fields_ref} = ['account_opening_reason'];
        $exception = exception { ok !BOM::User::Script::SiblingDataSync->run($args); };
        ok $exception =~ /Invalid file content/, 'Invalid CSV format';

        unlink $filename;

        ($fh, $filename) = tempfile(SUFFIX => ".csv");
        print $fh "binary_user_id,mf_login_ids,mf_tax_country,cr_tax_country,cr_login_ids\n";
        print $fh "value1,value2,value3,value4,value5\n";
        close $fh;
        $args->{file_path} = $filename;
        $exception = exception { ok(BOM::User::Script::SiblingDataSync->run($args)); };
        ok !$exception, 'Input is OK';
        unlink $filename;
        unlink((glob("/tmp/sync_output*.csv"))[0]);

    };

    $args->{dry_run} = 0;

    subtest 'Invalid MF login ID' => sub {

        my ($fh, $filename) = tempfile(SUFFIX => ".csv");
        print $fh "binary_user_id,mf_login_ids,mf_tax_country,cr_tax_country,cr_login_ids\n";
        print $fh "value1,value2,value3,value4,value5\n";
        close $fh;
        $args->{file_path} = $filename;
        $exception = exception { ok(BOM::User::Script::SiblingDataSync->run($args)); };
        ok !$exception, 'Input is OK';

        my $output_csv_file = (glob("/tmp/sync_output*.csv"))[0];
        my $aoh             = csv(
            in      => $output_csv_file,
            headers => "auto"
        );

        ok $aoh->[0]->{error} =~ /Invalid loginid: value2/, 'Invalid MF login ID';
        ok !$aoh->[0]->{cr_login_id},                       'No CR loginID';
        unlink $output_csv_file;
        unlink $filename;

    };

    subtest 'Invalid CR login ID' => sub {

        my $user = BOM::User->create(
            binary_user_id => 'random_binary_user_id',
            email          => 'someclient@binary.com',
            password       => 'Secret0'
        );

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            binary_user_id            => $user->id,
            broker_code               => 'MF',
            tax_identification_number => '123456789'
        });

        my $sibling_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            binary_user_id => $user->id,
            broker_code    => 'CR'
        });

        my ($fh, $filename) = tempfile(SUFFIX => ".csv");
        my $mf_login_id    = $client->loginid;
        my $binary_user_id = $client->binary_user_id;
        print $fh "binary_user_id,mf_login_ids,mf_tax_country,cr_tax_country,cr_login_ids\n";
        print $fh "$binary_user_id,$mf_login_id,value3,value4,value5\n";
        close $fh;

        $args->{file_path} = $filename;

        delete $args->{fields_ref};

        $exception = exception { ok(BOM::User::Script::SiblingDataSync->run($args)); };
        ok !$exception, 'Input is OK';

        my $output_csv_file = (glob("/tmp/sync_output*.csv"))[0];
        my $aoh             = csv(
            in      => $output_csv_file,
            headers => "auto"
        );

        ok $aoh->[0]->{error} =~ /Invalid loginid: value5/, 'Invalid CR login ID';
        ok $aoh->[0]->{cr_login_id},                        'Should have CR loginID';

        unlink $output_csv_file;
        unlink $filename;

    };

    subtest 'Fields are changed - Single field' => sub {

        for my $field (@all_fields) {

            my $user = BOM::User->create(
                email    => join('', rand_words(size => 2), '@', rand_words(size => 2), '.com'),
                password => 'Secret0'
            );

            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                binary_user_id => $user->id,
                broker_code    => 'MF',
                $field         => '12345678'
            });

            my $sibling_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                binary_user_id => $user->id,
                broker_code    => 'CR'
            });

            my $mf_login_id    = $client->loginid;
            my $binary_user_id = $client->binary_user_id;

            my ($fh, $filename) = tempfile(SUFFIX => ".csv");
            print $fh "binary_user_id,mf_login_ids,mf_tax_country,cr_tax_country,cr_login_ids\n";
            print $fh "$binary_user_id,$mf_login_id,value3,value4,$sibling_client->{loginid}\n";
            close $fh;
            $args->{file_path} = $filename;
            $exception = exception { ok(BOM::User::Script::SiblingDataSync->run($args)); };
            ok !$exception, 'Input is OK';

            $sibling_client = BOM::User::Client->new({loginid => $sibling_client->{loginid}});
            ok $sibling_client->$field eq $client->$field, $field . ' changed';

            my $output_csv_file = (glob("/tmp/sync_output*.csv"))[0];
            my $aoh             = csv(
                in      => $output_csv_file,
                headers => "auto"
            );

            ok $aoh->[0]->{cr_login_id} eq $sibling_client->{loginid}, 'Correct CR loginid in report';
            ok $aoh->[0]->{old_value} eq '',                           'Correct old_value in report';
            ok $aoh->[0]->{new_value} eq $sibling_client->$field,      'Correct new_value in report';
            ok $aoh->[0]->{updated_field} eq $field,                   'Correct updated_field in report';
            ok !$aoh->[0]->{error},                                    'No error in report';

            unlink $filename;
            unlink $output_csv_file;
        }

    };

    subtest 'Fields are changed - All fields' => sub {

        my $user = BOM::User->create(
            email    => join('', rand_words(size => 2), '@', rand_words(size => 2), '.com'),
            password => 'Secret0'
        );

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            binary_user_id => $user->id,
            broker_code    => 'MF',
        });

        for my $field (@all_fields) {
            $client->$field(rand_words(size => 8));
        }

        $client->save();

        my $sibling_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            binary_user_id => $user->id,
            broker_code    => 'CR'
        });

        my $mf_login_id    = $client->loginid;
        my $binary_user_id = $client->binary_user_id;

        my ($fh, $filename) = tempfile(SUFFIX => ".csv");
        print $fh "binary_user_id,mf_login_ids,mf_tax_country,cr_tax_country,cr_login_ids\n";
        print $fh "$binary_user_id,$mf_login_id,value3,value4,$sibling_client->{loginid}\n";
        close $fh;
        $args->{file_path} = $filename;
        $exception = exception { ok(BOM::User::Script::SiblingDataSync->run($args)); };
        ok !$exception, 'Input is OK';

        $sibling_client = BOM::User::Client->new({loginid => $sibling_client->{loginid}});

        my $output_csv_file = (glob("/tmp/sync_output*.csv"))[0];
        my $aoh             = csv(
            in      => $output_csv_file,
            headers => "auto"
        );

        for my $field_idx (0 .. $#all_fields) {
            my $field = $all_fields[$field_idx];
            ok $sibling_client->$field eq $client->$field,                      $field . ' changed';
            ok $aoh->[$field_idx]->{cr_login_id} eq $sibling_client->{loginid}, 'Correct CR loginid in report';
            ok $aoh->[$field_idx]->{old_value} eq '',                           'Correct old_value in report';
            ok $aoh->[$field_idx]->{new_value} eq $sibling_client->$field,      'Correct new_value in report';
            ok $aoh->[$field_idx]->{updated_field} eq $field,                   'Correct updated_field in report';
            ok !$aoh->[$field_idx]->{error},                                    'No error in report';
        }

        unlink $filename;
        unlink $output_csv_file;

    };

    subtest 'copy_data_for_all_clients' => sub {

        my @file_content = ();
        for my $i (0 .. 2) {
            my $user = BOM::User->create(
                email    => join('', rand_words(size => 2), '@', rand_words(size => 2), '.com'),
                password => 'Secret0'
            );

            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                binary_user_id => $user->id,
                broker_code    => 'MF',
            });

            for my $field (@all_fields) {
                $client->$field(rand_words(size => 8));
            }

            $client->save();

            my $cr_login_ids = join ",",
                map { BOM::Test::Data::Utility::UnitTestDatabase::create_client({binary_user_id => $user->id, broker_code => 'CR',})->loginid }
                (0 .. 2);

            push @file_content,
                {
                binary_user_id => $client->binary_user_id,
                mf_login_ids   => $client->loginid,
                mf_tax_country => 'random1',
                cr_tax_country => 'random2',
                cr_login_ids   => $cr_login_ids
                };
        }

        my $result = BOM::User::Script::SiblingDataSync::copy_data_for_all_clients(\@file_content, \@all_fields, $args->{dry_run});

        isa_ok($result, 'ARRAY', 'Result is an arrayref');

        for my $row (@file_content) {
            my $client       = BOM::User::Client->new({loginid => $row->{mf_login_ids}});
            my @cr_login_ids = split ",", $row->{cr_login_ids};
            for my $sibling_login_id (@cr_login_ids) {
                my $sibling = BOM::User::Client->new({loginid => $sibling_login_id});
                for my $field (@all_fields) {
                    ok $client->$field eq $sibling->$field, $field . ' changed';
                }
            }

        }
    };

    subtest 'copy_data_to_siblings' => sub {

        my $user = BOM::User->create(
            email    => join('', rand_words(size => 2), '@', rand_words(size => 2), '.com'),
            password => 'Secret0'
        );

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            binary_user_id => $user->id,
            broker_code    => 'MF',
        });

        for my $field (@all_fields) {
            $client->$field(rand_words(size => 8));
        }

        $client->save();

        my @cr_login_ids =
            map { BOM::Test::Data::Utility::UnitTestDatabase::create_client({binary_user_id => $user->id, broker_code => 'CR',})->loginid } (0 .. 2);

        BOM::User::Script::SiblingDataSync::copy_data_to_siblings($client, \@cr_login_ids, \@all_fields, $args->{dry_run});

        for my $sibling_login_id (@cr_login_ids) {
            my $sibling = BOM::User::Client->new({loginid => $sibling_login_id});
            for my $field (@all_fields) {
                ok $client->$field eq $sibling->$field, $field . ' changed';
            }
        }

    };
};

done_testing();
