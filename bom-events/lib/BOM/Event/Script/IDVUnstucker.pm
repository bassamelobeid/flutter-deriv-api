package BOM::Event::Script::IDVUnstucker;

=head1 NAME

BOM::Event::Script::IDVUnstucker - Unstuck pending IDV checks.

=head1 DESCRIPTION

Provides a retry mechanism for stuck pending IDV checks.

Time window is older than 1 day, but no more than 15.

After 15 days, the unstucker will fail the IDV check.

Up to 100 IDV requests per script run, by default.

=cut

use strict;
use warnings;

use BOM::Platform::Event::Emitter;
use BOM::Database::UserDB;
use Future::AsyncAwait;
use BOM::Event::Services;
use IO::Async::Loop;
use DataDog::DogStatsd::Helper;
use Syntax::Keyword::Try;
use Log::Any qw($log);
use BOM::User::IdentityVerification;
use BOM::Event::Actions::Client::IdentityVerification;
use JSON::MaybeUTF8 qw(:v2);

=head2 run

Unstuck checks that have been stuck in `pending` for a while.

=cut

async sub run {
    my ($self, $args) = @_;
    my $custom_limit = $args->{custom_limit} // 100;

    my $loop = IO::Async::Loop->new;

    my $documents = BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('select id, binary_user_id from idv.get_stuck_documents(?::INT)', {Slice => {}}, $custom_limit);
        });

    for my $document ($documents->@*) {
        my ($document_id, $binary_user_id) = @{$document}{qw/id binary_user_id/};
        my $user = BOM::User->new(id => $binary_user_id);

        if ($user) {
            # IDV is SVG only for now
            my ($svg_client) = $user->clients_for_landing_company('svg');

            if ($svg_client) {
                my $idv_model = BOM::User::IdentityVerification->new(user_id => $svg_client->binary_user_id);

                my $standby = $idv_model->get_standby_document();

                if ($standby) {
                    my $check = $idv_model->get_document_check_detail($document->{id});

                    if ($check) {
                        DataDog::DogStatsd::Helper::stats_inc('idv.unstucker.requested');
                        my $message_payload = BOM::Event::Actions::Client::IdentityVerification::idv_message_payload($svg_client, $standby);

                        # this will also update the updated_at, therefore the next idv.get_stuck_documents won't include it until 1 day or so
                        $idv_model->update_document_check({
                                document_id => $document->{id},
                                status      => +BOM::Event::Actions::Client::IdentityVerification::IDV_DOCUMENT_STATUS->{pending},
                                messages    => [
                                    +BOM::Event::Actions::Client::IdentityVerification::IDV_MESSAGES->{VERIFICATION_STARTED},
                                    'Unstuck mechanism triggered'
                                ],
                                provider     => $check->{provider},
                                request_body => encode_json_utf8 $message_payload,
                            });

                        BOM::Platform::Event::Emitter::emit('idv_verification', $message_payload);
                        await $loop->delay_future(after => 30);
                    }
                }
            }
        }
    }

    # db cleanup
    # flag those older hopeless documents as `failed`

    BOM::Database::UserDB::rose_db()->dbic->run(
        fixup => sub {
            $_->do('select * from idv.fail_older_stuck_documents()');
        });
}

1;
