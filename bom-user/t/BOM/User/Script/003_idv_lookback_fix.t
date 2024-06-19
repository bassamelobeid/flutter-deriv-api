use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use Log::Any::Test;
use Log::Any qw($log);

use BOM::Database::UserDB;
use Date::Utility;
use BOM::Config;
use BOM::User::Script::IDVLookbackFix;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use JSON::MaybeUTF8                            qw(decode_json_text);

subtest 'IDV Lookback Fix' => sub {
    my @zaig_clients;
    my @data_zoo_clients;
    my @onfido_clients;

    subtest 'Run on empty data' => sub {
        $log->clear();
        BOM::User::Script::IDVLookbackFix::run();

        $log->contains_ok(qr/Processed: 0/);
        $log->contains_ok(qr/Recovered: 0/);
        $log->contains_ok(qr/False positives: 0/);
    };

    subtest 'adding and looping through the pagination' => sub {
        @zaig_clients     = seed(15, 'zaig');
        @data_zoo_clients = seed(15, 'data_zoo');

        my $mock = Test::MockModule->new('BOM::User::Script::IDVLookbackFix');
        my $recover_hits;
        my $candidates_hits;

        $mock->mock(
            'recover',
            sub {
                $recover_hits++;

                # this splitting trick will only work if the database has even number of records!
                return $recover_hits % 2 == 0;
            });

        subtest 'pagination limit by default is 1000' => sub {
            my $one_thousand = [map { +{id => $_, binary_user_id => $_,} } (1 .. 1000)];

            $mock->mock(
                'candidates',
                sub {
                    $candidates_hits++;

                    if ($candidates_hits > 1) {
                        return [];
                    }

                    return $one_thousand;
                });

            $log->clear();
            $recover_hits    = 0;
            $candidates_hits = 0;
            BOM::User::Script::IDVLookbackFix::run();

            is $recover_hits,    1000, '1000 checks found';
            is $candidates_hits, 2,    '2 db hits';
            $log->contains_ok(qr/Processed: 1000/);
            $log->contains_ok(qr/Recovered: 500/);
            $log->contains_ok(qr/False positives: 500/);
        };

        $mock->mock(
            'candidates',
            sub {
                $candidates_hits++;

                return $mock->original('candidates')->(@_);
            });

        subtest 'pagination limit is overriden to 3' => sub {
            $log->clear();
            $recover_hits    = 0;
            $candidates_hits = 0;
            BOM::User::Script::IDVLookbackFix::run(3);

            is $recover_hits,    30, '30 checks found';
            is $candidates_hits, 11, '11 db hits';        # sadly one extra hit is required as 3 is divisor of 30
            $log->contains_ok(qr/Processed: 30/);
            $log->contains_ok(qr/Recovered: 15/);
            $log->contains_ok(qr/False positives: 15/);
        };

        subtest 'pagination limit is overriden to 4' => sub {
            $log->clear();
            $recover_hits    = 0;
            $candidates_hits = 0;
            BOM::User::Script::IDVLookbackFix::run(4);

            is $recover_hits,    30, '30 checks found';
            is $candidates_hits, 8,  '8 db hits';
            $log->contains_ok(qr/Processed: 30/);
            $log->contains_ok(qr/Recovered: 15/);
            $log->contains_ok(qr/False positives: 15/);
        };

        subtest 'pagination limit is overriden to 0' => sub {
            $log->clear();
            $recover_hits    = 0;
            $candidates_hits = 0;
            BOM::User::Script::IDVLookbackFix::run(0);

            is $recover_hits,    0, '0 checks found';
            is $candidates_hits, 1, '1 db hit';
            $log->contains_ok(qr/Processed: 0/);
            $log->contains_ok(qr/Recovered: 0/);
            $log->contains_ok(qr/False positives: 0/);
        };

        $mock->unmock_all;
    };

    subtest 'recover them' => sub {
        subtest '100% recovery' => sub {
            $log->clear();
            BOM::User::Script::IDVLookbackFix::run();

            $log->contains_ok(qr/Processed: 30/);
            $log->contains_ok(qr/Recovered: 30/);
            $log->contains_ok(qr/False positives: 0/);

            for (@data_zoo_clients) {
                my $cli = BOM::User::Client->new({loginid => $_});

                ok !$cli->status->poi_dob_mismatch,  'no longer a dob mismatch';
                ok !$cli->status->poi_name_mismatch, 'no longer a name mismatch';
                ok $cli->status->age_verification,   'age verified';
                is $cli->status->reason('age_verification'), 'data_zoo - age verified';

                my $idv_model = BOM::User::IdentityVerification->new(user_id => $cli->binary_user_id);
                my $document  = $idv_model->get_last_updated_document();
                is $document->{status}, 'verified', 'Status is verified after recovery';
                cmp_deeply decode_json_text($document->{status_messages}), [qw/ADDRESS_VERIFIED/], 'status messages is clean';

                my $check = $idv_model->get_document_check_detail($document->{id});
                cmp_deeply decode_json_text($check->{report}), {portal_id => 'dummy'}, 'report is unaffected';
            }

            for (@zaig_clients) {
                my $cli = BOM::User::Client->new({loginid => $_});

                ok !$cli->status->poi_dob_mismatch,  'no longer a dob mismatch';
                ok !$cli->status->poi_name_mismatch, 'no longer a name mismatch';
                ok $cli->status->age_verification,   'age verified';
                is $cli->status->reason('age_verification'), 'zaig - age verified';

                my $idv_model = BOM::User::IdentityVerification->new(user_id => $cli->binary_user_id);
                my $document  = $idv_model->get_last_updated_document();
                is $document->{status}, 'verified', 'Status is verified after recovery';
                cmp_deeply decode_json_text($document->{status_messages}), [qw/ADDRESS_VERIFIED/], 'status messages is clean';

                my $check = $idv_model->get_document_check_detail($document->{id});
                cmp_deeply decode_json_text($check->{report}), {portal_id => 'dummy'}, 'report is unaffected';
            }
        };

        subtest 'no checks left to process after full recovery' => sub {
            $log->clear();
            BOM::User::Script::IDVLookbackFix::run();

            $log->contains_ok(qr/Processed: 0/);
            $log->contains_ok(qr/Recovered: 0/);
            $log->contains_ok(qr/False positives: 0/);
        };

        subtest 'Onfido should be ignored' => sub {
            @onfido_clients = seed(10, 'metamap');

            # have to manually update the audit
            my $dbic = BOM::Database::ClientDB->new({
                    broker_code => 'CR',
                })->db->dbic;

            $dbic->run(
                fixup => sub {
                    $_->do(
                        'UPDATE audit.client_status SET reason = ? WHERE reason = ?',
                        {Slice => {}},
                        'Onfido - age verified',
                        'metamap - age verified'
                    );
                });

            $log->clear();
            BOM::User::Script::IDVLookbackFix::run();

            for (@onfido_clients) {
                my $cli = BOM::User::Client->new({loginid => $_});

                ok $cli->status->poi_dob_mismatch,  'is a dob mismatch';
                ok $cli->status->poi_name_mismatch, 'is a name mismatch';
                ok !$cli->status->age_verification, 'not age verified';
            }

            $log->contains_ok(qr/Processed: 10/);
            $log->contains_ok(qr/Recovered: 0/);
            $log->contains_ok(qr/False positives: 10/);

            subtest 'come back to metamap' => sub {
                $dbic->run(
                    fixup => sub {
                        $_->do(
                            'UPDATE audit.client_status SET reason = ? WHERE reason = ?',
                            {Slice => {}},
                            'metamap - age verified',
                            'Onfido - age verified'
                        );
                    });

                $log->clear();
                BOM::User::Script::IDVLookbackFix::run();

                $log->contains_ok(qr/Processed: 10/);
                $log->contains_ok(qr/Recovered: 10/);
                $log->contains_ok(qr/False positives: 0/);

                # note these are no longer onfido clients at this point
                for (@onfido_clients) {
                    my $cli = BOM::User::Client->new({loginid => $_});

                    ok !$cli->status->poi_dob_mismatch,  'no longer a dob mismatch';
                    ok !$cli->status->poi_name_mismatch, 'no longer a name mismatch';
                    ok $cli->status->age_verification,   'age verified';
                    is $cli->status->reason('age_verification'), 'metamap - age verified';

                    my $idv_model = BOM::User::IdentityVerification->new(user_id => $cli->binary_user_id);
                    my $document  = $idv_model->get_last_updated_document();
                    is $document->{status}, 'verified', 'Status is verified after recovery';
                    cmp_deeply decode_json_text($document->{status_messages}), [qw/ADDRESS_VERIFIED/], 'status messages is clean';

                    my $check = $idv_model->get_document_check_detail($document->{id});
                    cmp_deeply decode_json_text($check->{report}), {portal_id => 'dummy'}, 'report is unaffected';
                }
            };

            subtest 'no checks left to process after full recovery' => sub {
                $log->clear();
                BOM::User::Script::IDVLookbackFix::run();

                $log->contains_ok(qr/Processed: 0/);
                $log->contains_ok(qr/Recovered: 0/);
                $log->contains_ok(qr/False positives: 0/);
            };
        };
    };
};

sub seed {
    my ($n, $provider) = @_;

    my @loginids;
    my @seeds;
    my $pivot;

    for (1 .. $n) {
        my $user = BOM::User->create(
            email    => "000.$_.seededuser\@$provider.com",
            password => 'test',
        );

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client->binary_user_id($user->id);
        $client->save;

        $client->status->set('age_verification',  'system', "$provider - age verified");
        $client->status->set('poi_dob_mismatch',  'system', "$provider - name mismatch");
        $client->status->set('poi_name_mismatch', 'system', "$provider - dob mismatch");
        $client->status->clear_age_verification;

        $user->add_client($client);

        my $idv_model = BOM::User::IdentityVerification->new(user_id => $user->id);

        my $document = $idv_model->add_document({
            issuing_country => 'br',
            number          => "000.$_",
            type            => 'cpf',
        });

        $idv_model->update_document_check({
            document_id   => $document->{id},
            status        => 'refuted',
            messages      => ['DOB_MISMATCH', 'NAME_MISMATCH', 'ADDRESS_VERIFIED'],
            provider      => $provider,
            request_body  => '{}',
            response_body => '{}',
            report        => '{"portal_id": "dummy"}'
        });

        my $check = $idv_model->get_document_check_detail($document->{id});
        delete $check->{responded_at};
        delete $check->{requested_at};
        $pivot //= $check->{id} - 1;
        push @seeds,    $check;
        push @loginids, $client->loginid;
    }

    cmp_deeply [
        map { +{id => $pivot + $_, provider => $provider, report => '{"portal_id": "dummy"}', request => '{}', response => '{}', photo_id => [],} }
            (1 .. $n)], [@seeds], "database seeded with $n checks";

    return @loginids;
}

done_testing();
