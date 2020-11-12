use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Event::Actions::P2P;

use BOM::Test;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Database::ClientDB;

my $collector = BOM::Database::ClientDB->new({broker_code => 'FOG'})->db->dbic;

subtest chat_received => sub {
    my @payloads = ({
            message_id => 1000,
            created_at => 1593547606693,
            user_id    => 'that guy',
            channel    => 'sendbird_open_channel',
            type       => 'MESG',
            message    => 'Hello World',
            url        => '',
        },
        {
            message_id => 2000,
            created_at => 1593547606694,
            user_id    => 'the other guy',
            channel    => 'sendbird_open_channel',
            type       => 'FILE',
            message    => '',
            url        => 'http://whatever',
        });

    foreach my $payload (@payloads) {
        subtest 'chat_type_' . $payload->{type} => sub {
            my $result = BOM::Event::Actions::P2P::chat_received($payload);
            ok $result, 'The chat has been received';

            my $row = $collector->run(
                fixup => sub {
                    $_->selectrow_hashref(q{SELECT * FROM data_collection.p2p_chat_message WHERE id = ?}, undef, $payload->{message_id});
                });

            my $expected = {
                id           => $payload->{message_id},
                created_time => re('\s+'),
                chat_user_id => $payload->{user_id},
                message_type => $payload->{type},
                message_text => $payload->{message},
                file_url     => $payload->{url},
                channel_url  => $payload->{channel},
            };
            cmp_deeply $row, $expected, 'The database row matches';
        };
    }
};

done_testing();
