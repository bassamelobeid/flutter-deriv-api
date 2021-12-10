#!/usr/bin/env perl

use strict;
use warnings;

no indirect;

use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Async::HTTP;
use Syntax::Keyword::Try;

use URI;
use Log::Any qw($log);
use JSON::MaybeUTF8 qw(:v1);
use Getopt::Long;

use Crypt::CBC;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use BOM::User;
use BOM::User::Client;
use BOM::User::Password;
use BOM::Config;

GetOptions(
    'l|log=s'          => \(my $log_level = 'debug'),
    'd|dry_run=s'      => \(my $dry_run   = 0),
    'm|mt5_loginid=s'  => \my $mt5_loginid,
    'e|environment=s'  => \my $environment,
    's|trade_server=s' => \my $trade_server,
    'h|help'           => \my $help,
);

require Log::Any::Adapter;
Log::Any::Adapter->set(qw(Stdout), log_level => $log_level);

die 'Need mt5 loginid if dry run is enabled' if ($dry_run and not $mt5_loginid);

my $loop = IO::Async::Loop->new;
$loop->add(
    my $http = Net::Async::HTTP->new(
        decode_content => 1,
        fail_on_error  => 1,
        timeout        => 10,
    ));

my $user;
unless ($dry_run) {
    my @randstr = ("A" .. "Z", "a" .. "z");
    my $randstr;
    $randstr .= $randstr[rand @randstr] for 1 .. 3;

    my @randnum = ("0" .. "9");
    my $randnum;
    $randnum .= $randnum[rand @randnum] for 1 .. 5;

    my $email = "test_http_${randstr}_${randnum}_\@binary.com";

    my $name = $email;
    $name =~ s/\@.*//;
    $name =~ s/[^a-zA-Z,]//g;

    my $phone     = "+624175" . $randnum;
    my $last_name = $name . $randstr;

    my $hash_pwd      = BOM::User::Password::hashpw("Abcd1234");
    my $secret_answer = Crypt::NamedKeys->new(keyname => 'client_secret_answer')->encrypt_payload(data => "blah");

    try {
        $user = BOM::User->create(
            email          => $email,
            password       => $hash_pwd,
            email_verified => 1,
            email_consent  => 1
        );
        $log->debugf('User created. ID: %s, email: %s', $user->id, $email);
    } catch ($e) {
        $log->errorf('Failed to create user. Error: %s', $e);
        die;
    }

    my $client_details = {
        broker_code              => 'CR',
        residence                => 'in',
        client_password          => 'x',
        last_name                => $last_name,
        first_name               => 'Test account',
        email                    => $email,
        salutation               => 'Ms',
        address_line_1           => 'ADDR 1',
        address_city             => 'Cyber',
        phone                    => $phone,
        secret_question          => "Mother's maiden name",
        secret_answer            => $secret_answer,
        place_of_birth           => 'in',
        account_opening_reason   => 'Speculative',
        date_of_birth            => '1990-01-01',
        non_pep_declaration_time => time,
        address_postcode         => '121001',
    };

    my $cr_client;
    try {
        $cr_client = $user->create_client(%$client_details,);

        $cr_client->set_default_account('USD');

        $cr_client->user->set_tnc_approval;
        $cr_client->save();
        $log->debugf('Client created %s', $cr_client->loginid);
    } catch ($e) {
        $log->errorf('Failed to create client. Error: %s', $e);
        die;
    }
}

my $config = BOM::Config::mt5_webapi_config();

my %servers = (
    demo => [sort keys %{$config->{demo}}],
    real => [sort keys %{$config->{real}}],
);

$log->debugf('Servers: %s', \%servers);

async sub do_mt5_request {
    my (%args) = @_;

    my $url = $config->{mt5_http_proxy_url} . '/' . $args{server_type} . '_' . $args{server_identifier} . '/';

    my $res = await $http->do_request(
        method       => "POST",
        uri          => URI->new($url . $args{command}),
        content      => encode_json_utf8($args{params}),
        content_type => 'application/json',
    );
    $log->tracef('Received %s', $res);

    return decode_json_utf8($res->content);
}

(
    async sub {
        my $response_object;
        my $command;
        my $req_params;

        foreach my $server_type (keys %servers) {
            foreach my $server_identifier (@{$servers{$server_type}}) {
                next if ($environment  and $environment ne $server_type);
                next if ($trade_server and $trade_server ne $server_identifier);

                $log->debug('----------------------------------------');
                $log->debugf('>>>>> Server details: %s:%s', $server_type, $server_identifier);
                try {
                    unless ($dry_run) {
                        $command = "UserAdd";
                        $log->debugf('Command: %s', $command);
                        my $now = time;
                        $req_params = {
                            name          => "Proxy test $now",
                            pass_main     => "Abc1234de",
                            pass_investor => "Abc1234de",
                            leverage      => 100,
                            group         => $server_type . '\\' . $server_identifier . '\\synthetic\\svg_std_usd',
                        };

                        $response_object = await do_mt5_request(
                            server_type       => $server_type,
                            server_identifier => $server_identifier,
                            command           => $command,
                            params            => $req_params,
                        );
                        $mt5_loginid = $response_object->{user}{Login};
                        $log->debugf('%s:%s Created user (cmd: %s) login is %s', $server_type, $server_identifier, $command, $mt5_loginid);

                        # add to the user
                        $user->add_loginid('MTR' . $mt5_loginid);
                    }

                    $command = 'UserGet';
                    $log->debugf('Command: %s', $command);
                    $req_params = {
                        login => $mt5_loginid,
                    };
                    $response_object = await do_mt5_request(
                        server_type       => $server_type,
                        server_identifier => $server_identifier,
                        command           => $command,
                        params            => $req_params,
                    );
                    my $group = $response_object->{user}{group};
                    # response are not uniform, here login is lowercase in the answer from UserAdd is Login with capital L
                    $log->debugf('%s:%s Response for(cmd: %s)is %s', $server_type, $server_identifier, $command, $response_object->{user}->{login});

                    if ($group) {
                        $command = 'GroupGet';
                        $log->debugf('Command: %s', $command);
                        $req_params = {
                            group => $group,
                        };
                        $response_object = await do_mt5_request(
                            server_type       => $server_type,
                            server_identifier => $server_identifier,
                            command           => $command,
                            params            => $req_params,
                        );
                        $log->debugf('%s:%s Response for (cmd: %s)is %s', $server_type, $server_identifier, $command, $response_object->{group});

                        $command = 'UserLogins';
                        $log->debugf('Command: %s', $command);
                        $req_params = {
                            group => $group,
                        };
                        $response_object = await do_mt5_request(
                            server_type       => $server_type,
                            server_identifier => $server_identifier,
                            command           => $command,
                            params            => $req_params,
                        );
                        $log->debugf('%s:%s Response for (cmd: %s)is %s', $server_type, $server_identifier, $command, $response_object->{logins});
                    }

                    $command = 'UserPasswordCheck';
                    $log->debugf('Command: %s', $command);
                    $req_params = {
                        login    => $mt5_loginid,
                        password => 'Abc1234de',
                        type     => 'main',
                    };
                    $response_object = await do_mt5_request(
                        server_type       => $server_type,
                        server_identifier => $server_identifier,
                        command           => $command,
                        params            => $req_params,
                    );
                    $log->debugf('%s:%s Response for (cmd: %s)is %s', $server_type, $server_identifier, $command, $response_object);

                    $command = 'PositionGetTotal';
                    $log->debugf('Command: %s', $command);
                    $req_params = {
                        login => $mt5_loginid,
                    };
                    $response_object = await do_mt5_request(
                        server_type       => $server_type,
                        server_identifier => $server_identifier,
                        command           => $command,
                        params            => $req_params,
                    );
                    $log->debugf('%s:%s Response for (cmd: %s)is %s', $server_type, $server_identifier, $command, $response_object->{user}->{total});

                    $command = 'UserArchiveGet';
                    $log->debugf('Command: %s', $command);
                    $req_params = {
                        login => $mt5_loginid,
                    };
                    $response_object = await do_mt5_request(
                        server_type       => $server_type,
                        server_identifier => $server_identifier,
                        command           => $command,
                        params            => $req_params,
                    );
                    $log->debugf('%s:%s Response for (cmd: %s)is %s', $server_type, $server_identifier, $command, $response_object->{user});
                } catch ($e) {
                    $log->errorf('Failed with %s', $e);
                }
            }
        }
    })->()->get;

1;
