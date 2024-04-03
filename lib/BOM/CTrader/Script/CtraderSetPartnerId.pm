package BOM::CTrader::Script::CtraderSetPartnerId;

use strict;
use warnings;
use BOM::Config;
use BOM::Config::Redis;
use BOM::Database::CommissionDB;
use BOM::Database::UserDB;
use BOM::User::Client;
use BOM::User;
use Date::Utility;
use feature qw(state);
use Future::AsyncAwait;
use Future::Utils qw(fmap_void try_repeat);
use Getopt::Long;
use HTTP::Tiny;
use IO::Async::Loop;
use JSON::MaybeUTF8 qw(:v1);
use Log::Any        qw($log);
use Mojo::JSON      qw(encode_json);
use Net::Async::Redis;
use Object::Pad;
use Pod::Usage;
use Syntax::Keyword::Try;
use YAML::XS;

=head1 BOM::CTrader::Script::CtraderSetPartnerId

This is script is used to set new partner ID on cTrader
for our affiliates that has recently sign up for IB commission plan. 

=head1 SYNOPSIS

The methods that are used to process the clients are

=cut 

class BOM::CTrader::Script::CtraderSetPartnerId {

    use constant {
        CTRADER_PARTNER_ID_REDIS_KEY => 'CTRADER_PARTNER_ID',
        HTTP_TIMEOUT_SECONDS         => 20,
    };

    my ($settings, $date, $all, $commission_db, $user_db);

    my $global_loop = IO::Async::Loop->new;

    $global_loop->add(
        # We will use ctrader redis to store cTrader Partner ID related keys
        my $redis = Net::Async::Redis->new(
            uri  => BOM::Config::Redis::redis_config('ctrader', 'write')->{uri},
            auth => BOM::Config::Redis::redis_config('ctrader', 'write')->{password},
        ));

=head2 new

Initialise module with params. It takes --date and --all as params

=cut

    BUILD {
        %$settings = @_;
        $date      = $settings->{date} // Date::Utility->new()->minus_time_interval('1d')->truncate_to_day->date;
        $all       = $settings->{all}  // 0;

        $commission_db = BOM::Database::CommissionDB::rose_db();
        $user_db       = BOM::Database::UserDB::rose_db();
    }

=head2 start

The main method to start the process of setting new partner ID

=cut

    async method start {
        try {

            $log->infof("\nStarting Script ...");

            $all ? $log->infof("\n\nProcessing all IB accounts") : $log->infof("\n\nProcessing IB accounts created on [%s]", $date);

            # Get the list of IBs with their binary_user_id
            my $ib_list = await $self->_get_ib_details_from_db($date, $all);

            foreach my $ib_row_id (keys %{$ib_list}) {

                my $ib_binary_user_id = $ib_list->{$ib_row_id}->{binary_user_id};

                # Check CTID for IB
                my $ib_ctid = await $self->_get_ctid_of_ib($ib_binary_user_id);

                $ib_ctid
                    ? $self->_check_partner_id($ib_ctid->[0], $ib_binary_user_id)->get
                    : $log->debugf("\t No CTID found for [%s] ...", $ib_binary_user_id);
            }

            $log->infof("\nScript Finished ...");

        } catch ($e) {
            $log->errorf("An error has occurred: $e");
            die;
        }

    }

=head2 _get_ib_details_from_db

A method to query the affiliate.affiliate table to return the list of IBs.

Retuns a list of IBs from affiliate.affiliate table.

=cut

    async method _get_ib_details_from_db {

        my ($date, $all) = @_;

        $log->debugf("\n\nFetching IB list from affiliate.affiliate table ...");

        try {

            my ($res) = $commission_db->dbic->run(
                fixup => sub {
                    $_->selectall_hashref('SELECT * FROM affiliate.get_ib_details(?)', 'id', undef, ($all ? undef : $date));
                });

            $log->debugf("Finished fetching IB list from affiliate.affiliate table");
            return $res;

        } catch ($e) {
            $log->errorf("Exception thrown while querying data : error [%s]", $e);
        }

    }

=head2 _get_ctid_of_ib

A method to query ctrader.binary_user_userid_map to return the CTID of the IB using binary_user_id.

=over 4

=item * C<$binary_user_id> - The binary_user_id of the IB account

=back

Returns the CTID of the IB.

=cut

    async method _get_ctid_of_ib {
        my ($binary_user_id) = @_;

        $log->debugf("\n\nFetching IB's CTID from ctrader.binary_user_userid_map table for [%s] ...", $binary_user_id);

        try {

            my ($res) = $user_db->dbic->run(
                fixup => sub {
                    $_->selectall_array(q{SELECT * FROM ctrader.get_ctrader_userid(?)}, undef, $binary_user_id);
                });

            $log->debugf("Finished fetching IB's CTID from ctrader.binary_user_userid_map table");
            return $res;

        } catch ($e) {
            $log->errorf("Exception thrown while querying data : error [%s]", $e);
        }

    }

=head2 _check_partner_id

A method to get cTrader's partner ID. 
It first checks if the partner ID exists in Redis, if not call cTrader API to get partner ID. 
If still not found, then we call cTrader API to set the Partner ID and save it to Redis as well.

The reason to check Redis first is to reduce cTrader API calls.

=over 4

=item * C<$ctid> - The CTID of the IB account

=back

=cut

    async method _check_partner_id {
        my ($ctid, $ib_binary_user_id) = @_;

        my $partner_id;

        try {
            my $redis_key_exists = await $redis->exists(CTRADER_PARTNER_ID_REDIS_KEY);

            if ($redis_key_exists) {
                $log->debugf("\t Fetching IB partner ID from Redis for CTID [%s] ...", $ctid);

                # Check to see if there's Partner ID stored in Redis
                $partner_id = await $redis->hget(CTRADER_PARTNER_ID_REDIS_KEY, $ctid);
            }

            unless ($partner_id) {
                $log->debugf("\t IB partner ID not found in Redis. Calling cTrader API to get partner ID ...");

                # Call cTrader API to get Partner ID.
                my $ctrader_resp = [];
                $ctrader_resp = await $self->_ctrader_get_partner_id($ctid);

                if (scalar(@$ctrader_resp) == 0) {

                    $log->debugf("\t IB partner ID not found via cTrader API. Setting Partner ID via cTrader API ...");

                    # Call cTrader API to set Partner ID.
                    await $self->_ctrader_set_partner_id($ctid, $ib_binary_user_id)->then(
                        async sub {
                            # Save Partner ID to Redis
                            await $self->_save_partner_id_to_redis($ctid, $ib_binary_user_id);
                        });

                } else {
                    $log->debugf("\t Found IB partner ID via cTrader API for CTID [%s] - [%s] ...", $ctid, $ctrader_resp->[0]{partnerId});

                    # Save Partner ID to Redis
                    await $self->_save_partner_id_to_redis($ctid, $ib_binary_user_id);

                    $log->debugf("\t Moving on to next IB ...");
                }
            } else {
                $log->debugf("\t Found IB partner ID from Redis for [%s] - [%s] ...", $ctid, $partner_id);
                $log->debugf("\t Moving on to next IB ...");
            }

        } catch ($e) {
            $log->errorf("Exception thrown while getting IB partner ID : error [%s]", $e);
        }

    }

=head2 _ctrader_get_partner_id

A method to get cTrader Partner ID via cTrader API

=over 4

=item * C<$ctid> - The CTID of the IB account

=back

Returns the Partner ID of the IB.

=cut

    async method _ctrader_get_partner_id {
        my ($ctid) = @_;

        my $partner_id;

        try {
            $partner_id = await $self->_call_api(
                method  => "ctid_readreferral",
                path    => "cid",
                payload => {userId => $ctid});

            return $partner_id;
        } catch ($e) {
            $log->errorf("Exception thrown while getting Partner ID from cTrader : error [%s]", $e);
        }
    }

=head2 _ctrader_set_partner_id

A method to set cTrader Partner ID via cTrader API

=over 4

=item * C<$ctid> - The CTID of the IB account

=back
=cut

    async method _ctrader_set_partner_id {
        my ($ctid, $ib_binary_user_id) = @_;

        try {
            await $self->_call_api(
                method  => "ctid_referral",
                path    => "cid",
                payload => {
                    userId    => $ctid,
                    partnerId => $ib_binary_user_id,
                });

        } catch ($e) {
            $log->errorf("Exception thrown while setting Partner ID from cTrader : error [%s]", $e);
        }
    }

=head2 _save_partner_id_to_redis

A method to save the Partner ID to Redis

=over 4

=item * C<$ctid> - The CTID of the IB account

=item * C<$ib_binary_user_id> - The binary_user_id of the IB account

=back
=cut

    async method _save_partner_id_to_redis {
        my ($ctid, $ib_binary_user_id) = @_;

        try {
            # Write to Redis after setting the Partner ID on cTrader
            await $redis->hmset(CTRADER_PARTNER_ID_REDIS_KEY, $ctid, $ib_binary_user_id);

            # Check to see if Partner ID is successfully added to Redis.
            my $partner_id = await $redis->hget(CTRADER_PARTNER_ID_REDIS_KEY, $ctid);

            if (!$partner_id) {
                $log->debugf("\t !!! Failed to insert IB partner ID to Redis for CTID [%s] !!!", $ctid);
            } else {
                $log->debugf("\t IB partner ID inserted to Redis ...");
            }

        } catch ($e) {
            $log->errorf("Exception thrown while setting Partner ID from cTrader : error [%s]", $e);
        }
    }

=head2 _call_api

Calls API service with given params.

Takes the following named arguments, plus others according to the method.

=over 4

=item * C<method>. Required.

=back

=cut

    async method _call_api {
        my (%args) = @_;

        # Regardless of the proxy server, when we call cTrader API to set/read Partner ID,
        # its on the CTID account instead of live/demo account.
        # CTID account is one level above live/demo account.
        # https://wikijs.deriv.cloud/en/CFD/cTrader/Backend-System/cTrader-API-Documentation
        $args{server} = "real";

        state $http_tiny = HTTP::Tiny->new(timeout => HTTP_TIMEOUT_SECONDS);

        my $config = YAML::XS::LoadFile('/etc/rmg/ctrader_proxy_api.yml');

        my $ctrader_servers = {
            real => $config->{ctrader_live_proxy_url},
            demo => $config->{ctrader_demo_proxy_url}};

        my $server_url = $ctrader_servers->{$args{server}} . $args{path};

        my $headers = {
            'Accept'       => "application/json",
            'Content-Type' => "application/json",
        };
        my $payload = encode_json_utf8(\%args);
        my $resp;

        try {
            $resp = $http_tiny->post(
                $server_url,
                {
                    content => $payload,
                    headers => $headers
                });

            $resp->{content} = decode_json_utf8($resp->{content} || '{}');
            die unless $resp->{success};    # we expect some calls to fail, eg. client_get
            return $resp->{content};
        } catch ($e) {
            $log->debugf("\n \t [X] Ctrader call failed for cTID %s: %s, call args: %s", $args{payload}{userId}, $resp, \%args);
            return $e if ref $e eq 'HASH';
        }
    }

}

1;
