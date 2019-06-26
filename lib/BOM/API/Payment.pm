package BOM::API::Payment;

use strict;
use warnings;
use 5.008_001;
use Plack::Builder;
use Router::Resource;
use parent qw(Plack::Component);
use Plack::Request;
use Plack::Response;
use Encode;
use JSON::MaybeXS;
use Scalar::Util qw/blessed/;
use Try::Tiny;
use Log::Dispatch::File;
use Log::Dispatch::Screen;
use Data::Dumper;

# BOM
use BOM::User::Client;
use Digest::SHA ();
use XML::Simple;

use BOM::API::Payment::Account;
use BOM::API::Payment::Client;
use BOM::API::Payment::Session;
use BOM::API::Payment::DoughFlow;

sub to_app {    ## no critic (RequireArgUnpacking,Subroutines::RequireFinalReturn)
    my $router = router {
        resource '/ping' => sub {
            GET { {status => 'up'} };
        };
        resource '/account' => sub {
            GET { BOM::API::Payment::Account->new(env => $_[0])->account_GET };
        };

        resource '/client' => sub {
            GET { BOM::API::Payment::Client->new(env => $_[0])->client_GET };
        };

        resource '/session' => sub {
            GET {
                BOM::API::Payment::Session->new(env => $_[0])->session_GET;
            }
        };
        resource '/session/validate' => sub {
            GET {
                BOM::API::Payment::Session->new(env => $_[0])->session_validate_GET;
            }
        };

        # DoughFlow
        resource qr'/transaction/payment/doughflow/record$' => sub {
            GET { BOM::API::Payment::DoughFlow->new(env => $_[0])->record_GET };
        };
        resource '/transaction/payment/doughflow/deposit' => sub {
            POST {
                BOM::API::Payment::DoughFlow->new(env => $_[0])->deposit_POST;
            }
        };
        resource '/transaction/payment/doughflow/deposit_validate' => sub {
            GET {
                BOM::API::Payment::DoughFlow->new(env => $_[0])->deposit_validate_GET;
            }
        };
        resource '/transaction/payment/doughflow/withdrawal_validate' => sub {
            GET {
                BOM::API::Payment::DoughFlow->new(env => $_[0])->withdrawal_validate_GET;
            }
        };
        resource '/transaction/payment/doughflow/withdrawal' => sub {
            POST {
                BOM::API::Payment::DoughFlow->new(env => $_[0])->withdrawal_POST;
            }
        };
        resource '/transaction/payment/doughflow/withdrawal_reversal' => sub {
            POST {
                BOM::API::Payment::DoughFlow->new(env => $_[0])->withdrawal_reversal_POST;
            }
        };
        resource '/transaction/payment/doughflow/create_payout' => sub {
            POST {
                BOM::API::Payment::DoughFlow->new(env => $_[0])->create_payout_POST;
            }
        };
        resource '/transaction/payment/doughflow/update_payout' => sub {
            POST {
                BOM::API::Payment::DoughFlow->new(env => $_[0])->update_payout_POST;
            }
        };
        resource '/transaction/payment/doughflow/record_failed_deposit' => sub {
            POST {
                BOM::API::Payment::DoughFlow->new(env => $_[0])->record_failed_deposit_POST;
            }
        };
    };

    my $trace_log = $ENV{PAYMENTAPI_LOG_FILE} || '/var/log/httpd/paymentapi_trace.log';
    my $trace_lvl = 'warn';
    my $syslg_lvl = 'warn';
    my $logformat = sub { my %msg = @_; my $lvl = sprintf '%-7s', uc $msg{level}; "$lvl $msg{message}" };
    my $log       = Log::Dispatch->new;
    $log->add(
        Log::Dispatch::File->new(
            newline   => 1,
            callbacks => $logformat,
            min_level => $trace_lvl,
            mode      => '>>',
            filename  => $trace_log
        ));
    $log->add(
        Log::Dispatch::Screen->new(
            newline   => 1,
            callbacks => $logformat,
            min_level => $syslg_lvl
        )) unless $ENV{PLACK_TEST_IMPL};
    $log->info(sprintf "PaymentAPI Server Starting at %s. PID $$. Tracing to $trace_log. Environment: %s", scalar(localtime), Dumper(\%ENV));

    builder {

        enable "Plack::Middleware::ContentLength";

        enable_if {
            $_[0]->{PATH_INFO} ne '/ping'
        }
        sub {
            my $app = shift;
            sub {
                my $env = shift;
                $env->{log} = $log;

                # pre-processing: log this request
                my $req = Plack::Request->new($env);
                if ($log->is_debug) {
                    my $now = Date::Utility->new;
                    my $msg = sprintf "\n%s\n%s Request is %s %s\n", '=' x 80, $now->datetime_yyyymmdd_hhmmss, $req->method, $req->path;
                    $msg .= sprintf "Query %s", Dumper($req->query_parameters) if $req->query_parameters->keys;
                    $msg .= sprintf "Body  %s", ($req->content || 'empty') if $req->method eq 'POST';
                    $log->debug($msg);
                }

                # run the app, but trap breakages here so we can trace.
                my $ref = eval { $app->($env) } || do {
                    my $error = $@;
                    $log->error($error);
                    [500, [], ['Server Error']];
                };

                # post-processing: log this response
                if ($log->is_debug) {
                    my $res = Plack::Response->new(@$ref);
                    my $msg = sprintf "\n%s\n%s\n%s\n%s\n%s", '_' x 80, $res->status, Dumper($res->headers), join('', @{$res->body}), '_' x 80;
                    $log->debug($msg);
                }

                return $ref;
            };
        };

        # first try DoughFlow Auth
        enable_if {
            $_[0]->{PATH_INFO} ne '/ping';
        }
        'Auth::DoughFlow',
            header_name      => 'X-BOM-DoughFlow-Authorization',
            secret_key       => 'N73X49dS6SmX9Tf4',
            continue_on_fail => 1;                                 # allow to fallback to Basic
                                                                   # fallback to Basic only DoughFlow failed
        enable_if {
            $_[0]->{PATH_INFO} ne '/ping' and not $_[0]->{'X-DoughFlow-Authorization-Passed'};
        }
        "Auth::Basic", authenticator => \&authen_cb;

        sub {
            my $env = shift;
            my $req = Plack::Request->new($env);

            # make it both supports the url ends with / or not
            # eg /account/ and /account should both work
            $env->{PATH_INFO} =~ s{/$}{};

            my $content_type = $req->header('Content-Type');
            my ($xs, $client_loginid);
            ## set user for DoughFlow
            if ($env->{'X-DoughFlow-Authorization-Passed'}) {
                $client_loginid = scalar($req->param('client_loginid'));
                if (not $client_loginid and $content_type and $content_type =~ 'xml') {
                    $xs = XML::Simple->new(ForceArray => 0);
                    if ($req->content) {
                        my $data = $xs->XMLin($req->content);
                        $client_loginid = $data->{client_loginid};
                    }
                }
                unless ($client_loginid) {
                    return [401, [], ['Authorization required']];
                }
                unless ($client_loginid =~ /^[A-Z]{2,6}\d{3,}$/) {
                    return [401, [], ['Authorization required']];
                }
                my $client = BOM::User::Client->new({
                        loginid => $client_loginid,
                    })
                    || do {
                    return [401, [], ['Authorization required']];
                    };
                $env->{BOM_USER} = $client;
            }

            my $r = $router->dispatch($env);
            return $r if ref($r) eq 'ARRAY';    # from Router::Resource 405 or 404

            if ($content_type and $content_type =~ 'xml') {
                $xs = XML::Simple->new(ForceArray => 0) unless $xs;

                if (blessed($r)) {              # Plack::Response
                    $r->content_type('text/xml');
                    $r->body($xs->XMLout({data => $r->body || {}}));
                    return $r->finalize;
                }

                my $code = delete $r->{status_code} || 200;
                return [$code, ['Content-Type' => 'text/xml; charset=utf-8'], [$xs->XMLout({data => $r || {}})]];
            }

            return $r->finalize if blessed($r);    # Plack::Response

            # JSON by default
            my $code = delete $r->{status_code} || 200;
            my $body = Encode::encode_utf8(JSON::MaybeXS->new->encode($r));
            return [$code, ['Content-Type' => 'application/json; charset=utf-8'], [$body]];
        };
    };
}

sub authen_cb {
    my ($username, $password, $env) = @_;

    my $client = try {
        BOM::User::Client->new({loginid => $username});
    } || return;
    return unless Digest::SHA::sha256_hex($password) eq $client->client_password;
    $env->{BOM_USER} = $client;
    return 1;
}

1;

=head1 NAME

Payment API

 [![Build Status](https://magnum.travis-ci.com/regentmarkets/bom-paymentapi.svg?token=NEzjfN4CW3UPLpqc9zRU&branch=master)](https://magnum.travis-ci.com/regentmarkets/bom-paymentapi)
 [![Coverage Status](https://coveralls.io/repos/regentmarkets/bom-paymentapi/badge.png?branch=master)](https://coveralls.io/r/regentmarkets/bom-paymentapi?branch=master)

=head1 TEST

    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -MBOM::Test t/BOM/001_structure.t

=cut
