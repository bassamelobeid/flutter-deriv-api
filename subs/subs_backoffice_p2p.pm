## no critic (RequireExplicitPackage)
use strict;
use warnings;

use BOM::Backoffice::Request qw(request);
use Syntax::Keyword::Try;

sub p2p_agent_register {
    my $client = shift;

    try {
        $client->p2p_agent_create(request->param('agent_name'));

        return {
            success => 1,
            message => $client->loginid . ' has been registered as P2P Agent'
        };
    }
    catch {
        my ($error_code, $error_msg) = ($@, undef);

        if ($error_code =~ 'AgentNameRequired') {
            $error_msg = 'P2P Agent name is required.';
        } elsif ($error_code =~ 'AlreadyRegistered') {
            $error_msg = $client->loginid . ' is already registered as a P2P Agent.';
        } else {
            $error_msg = $client->loginid . ' could not be registered as a P2P Agent. Error code: ' . $error_code;
        }

        return {
            success => 0,
            message => $error_msg
        };
    }
}

sub p2p_agent_update {
    my $client = shift;

    try {
        if (
            $client->p2p_agent_update(
                agent_name       => request->param('agent_name'),
                is_authenticated => request->param('authenticated'),
                is_active        => request->param('active'),
            ))
        {
            return {
                success => 1,
                message => 'P2P Agent for ' . $client->loginid . ' updated.'
            };
        }
    }
    catch {
        my ($error_code, $error_msg) = ($@, undef);

        if ($error_code =~ 'AgentNameRequired') {
            $error_msg = 'P2P Agent name is required.';
        } elsif ($error_code =~ 'AgentNotAuthenticated') {
            $error_msg = 'P2P Agent for ' . $client->loginid . ' should be authenticated in order to update its details.';
        } else {
            $error_msg = 'P2P Agent for ' . $client->loginid . ' could not be updated. Error code: ' . $error_code;
        }

        return {
            success => 0,
            message => $error_msg
        };
    }
}

sub p2p_process_action {
    my $client = shift;
    my $action = shift;
    my $response;

    if ($action eq 'p2p.agent.register') {
        $response = p2p_agent_register($client);
    } elsif ($action eq 'p2p.agent.update') {
        $response = p2p_agent_update($client);
    }

    if ($response) {
        my $color = $response->{success} ? 'green' : 'red';
        my $message = $response->{message};

        return "<p style='color:$color; font-weight:bold;'>$message</p>";
    }
}

1;
