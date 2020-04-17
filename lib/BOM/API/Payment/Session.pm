package BOM::API::Payment::Session;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use BOM::Database::ClientDB;
use BOM::Database::Model::HandoffToken;
use BOM::Config::Runtime;
use LandingCompany::Registry;

sub session_GET {
    my $c       = shift;
    my $log     = $c->env->{log};
    my $client  = $c->user;
    my $loginid = $client->loginid;

    $log->debug("session_GET for $client, DF Auth-Passed header " . ($c->env->{'X-DoughFlow-Authorization-Passed'} || 'missing'));

    ## only allow Basic Auth call
    return $c->throw(401, 'Authorization required')
        if $c->env->{'X-DoughFlow-Authorization-Passed'};

    my $cb = BOM::Database::ClientDB->new({
        client_loginid => $loginid,
    });

    my $handoff_token_key;
    my $handoff_token;
    if ($c->request_parameters->{'handoff_tokenid'}) {
        $log->debug('handoff_tokenid included, fetching handoff_token');
        $handoff_token_key = $c->request_parameters->{'handoff_tokenid'};
        $handoff_token     = BOM::Database::Model::HandoffToken->new(
            db                 => $cb->db,
            data_object_params => {
                key            => $handoff_token_key,
                client_loginid => $loginid,
                expires        => time + 4 * 60,
            },
        );
        if (not $handoff_token->exists and not $handoff_token->is_valid) {
            return $c->status_bad_request('Invalid or missing handoff token in request');
        }
    } else {
        $log->debug('Creating handoff_token');
        # generate handoff_token token
        $handoff_token_key = BOM::Database::Model::HandoffToken->generate_session_key;
        $handoff_token     = BOM::Database::Model::HandoffToken->new({
                db                 => $cb->db,
                data_object_params => {
                    key            => $handoff_token_key,
                    client_loginid => $loginid,
                    expires        => time + 4 * 60,

                },
            });
        $handoff_token->save;
    }

    return {
        loginid            => $client->loginid,
        handoff_token_key  => $handoff_token_key,
        handoff_token_data => {
            key            => $handoff_token->key,
            client_loginid => $handoff_token->client_loginid,
            expires        => $handoff_token->expires->datetime,
        },
    };
}

sub session_validate_GET {
    my $c = shift;

    ## only allow Basic Auth call
    unless ($c->env->{'X-DoughFlow-Authorization-Passed'}) {
        return $c->throw(401, 'Authorization required');
    }

    # This is where we should check to make sure that the token
    # is a valid session. For now we'll just check that
    # it is 32 hex characters :-/
    unless (exists $c->request_parameters->{token} and $c->request_parameters->{token} =~ /^[a-f0-9]{40}$/) {
        return $c->status_bad_request('Invalid or missing token in request');
    }
    # we have a token, so lets make a db
    my $connection_builder = BOM::Database::ClientDB->new({
        client_loginid => $c->user->loginid,
    });
    my $token_key = $c->request_parameters->{token};
    # Get the existing handoff token
    my $handoff_token = BOM::Database::Model::HandoffToken->new({
        data_object_params => {'key' => $token_key},
        db                 => $connection_builder->db
    });
    # ->exists is important because it does a SPECULATIVE LOAD
    # this allows us to check if the object exists in the DB without
    # throwing a db exception if it doesnt exist
    # REALLY ANNOYING
    if (!$handoff_token->exists) {
        return $c->status_bad_request('No token found', 'bom_paymentapi.session.no_token_found');
    }

    if (not $handoff_token->is_valid or ($handoff_token->client_loginid ne $c->user->loginid)) {
        return $c->status_bad_request('Token invalid or expired');
    }

    # Assuming that check succeeded, let the client know that we
    # have accepted the validation request and also provide a
    # link to additional client details that might be useful
    my $client_uri = $c->req->base->clone;
    $client_uri->path('/paymentapi/client/');
    $client_uri->query('loginid=' . $c->user->loginid);
    return {
        status  => 'accepted',
        details => $client_uri->as_string,
    };
}

no Moo;

1;
