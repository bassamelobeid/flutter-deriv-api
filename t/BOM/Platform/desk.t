use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Database::ClientDB;
use BOM::Platform::Desk;
use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );

my $user = BOM::User->create(
    email          => 'test@binary.com',
    password       => BOM::User::Password::hashpw('abcd'),
    email_verified => 1,
);

my $collector_db = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
        operation   => 'collector'
    })->db->dbic;

$collector_db->run(
    ping => sub {
        $_->do('INSERT INTO data_collection.s3_bucket VALUES(?, ?)', undef, 1, 'binary-desk-com-backup');
    });

my $desk_mock = Test::MockModule->new('BOM::Platform::Desk');

sub insert_record_into_db {
    my @records_to_insert = @_;

    my $query = 'INSERT INTO data_collection.s3_user_file VALUES' . join ',', map { '(?, ?, ?)' } @records_to_insert;

    my $user_id = $user->id;

    my @params = map { (1, $user_id, $_) } @records_to_insert;

    lives_ok {
        $collector_db->run(
            ping => sub {
                $_->do($query, undef, @params);
            });
    }
}

subtest 'initialization' => sub {
    throws_ok {
        BOM::Platform::Desk->new
    }
    qr/Missing required arguments: user/;

    lives_ok {
        BOM::Platform::Desk->new(user => $user);
    }
    'Instance was created successfully';
};

subtest 'get_user_file_path' => sub {
    my $desk_instance = BOM::Platform::Desk->new(user => $user);

    my @files = $desk_instance->get_user_file_path()->get;

    is scalar @files, 0, 'get_user_files returns no records.';

    my @records_to_insert_1 = ('desk/customer/X.json', 'zendesk-data/tickets/X.json', 'zendesk-data/attachments/X_X.jpeg',);

    insert_record_into_db(@records_to_insert_1);

    @files = $desk_instance->get_user_file_path()->get;

    is scalar @files, 3, 'records have been retrieved correctly.';

    $desk_mock->mock(
        '_get_file_path_s3',
        sub {
            return Future->done(('desk/case/X/message.json', 'desk/case/X/history.json', 'desk/case/X/replies/X.json'));
        });

    my @records_to_insert_2 = ('desk/case/X/');

    insert_record_into_db(@records_to_insert_2);

    @files = sort $desk_instance->get_user_file_path()->get;

    is scalar @files, 6, 'records are retrieved from both db and s3 successfully.';

    my @records_to_check = (@records_to_insert_1, ('desk/case/X/message.json', 'desk/case/X/history.json', 'desk/case/X/replies/X.json'));

    my $i = 0;
    foreach my $file_path (sort @records_to_check) {
        is $file_path, $files[$i++], 'file paths match correctly.';
    }
};

subtest 'anonymize_user' => sub {
    my $desk_instance = BOM::Platform::Desk->new(user => $user);

    $desk_mock->mock('_delete_user_file_path_s3', sub { Future->done(1) });

    my $return_value = $desk_instance->anonymize_user()->get;

    is $return_value, 1, 'anonymize user executed successfully';

    my @files = $desk_instance->get_user_file_path()->get;

    is scalar @files, 0, 'files were deleted successfully';
};

done_testing();
