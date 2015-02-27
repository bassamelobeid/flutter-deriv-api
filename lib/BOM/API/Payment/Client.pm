package BOM::API::Payment::Client;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use BOM::Database::Model::DoughFlowAddressDiff;
use BOM::Platform::Helper::Model::DoughFlowAddressDiff;
use Try::Tiny;
use Data::Dumper;

sub client_GET {
    my $c      = shift;
    my $env    = $c->env;
    my $client = $c->user;
    my $log    = $env->{log};

    my $r = {
        loginid               => $client->loginid,
        email                 => $client->email,
        first_name            => $client->first_name,
        last_name             => $client->last_name,
        salutation            => $client->salutation,
        address_line_1        => $client->address_line_1,
        address_line_2        => $client->address_line_2,
        address_city          => $client->address_city,
        address_state         => $client->address_state,
        address_postcode      => $client->address_postcode,
        country               => $client->residence,
        phone                 => $client->phone,
        fax                   => $client->fax,
        date_joined           => $client->date_joined,
        restricted_ip_address => $client->restricted_ip_address,
        gender                => $client->gender,
    };
    return $r;
}

sub address_diff_GET {
    my $c = shift;

    my $client = $c->user;
    return {
        loginid          => $client->loginid,
        address_line_1   => $client->address_line_1,
        address_line_2   => $client->address_line_2,
        address_city     => $client->address_city,
        address_state    => $client->address_state,
        address_postcode => $client->address_postcode,
        country          => $client->residence,
    };
}

sub address_diff_POST {    ## no critic (Subroutines::RequireFinalReturn)
    my $c = shift;

    my $client = $c->user;

    my $connection_builder = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
    });
    my $doughflow_address_diff = BOM::Database::Model::DoughFlowAddressDiff->new({
        data_object_params => {'client_loginid' => $client->loginid},
        db                 => $connection_builder->db
    });

    try {
        my @valid_fields = qw(street city province country pcode);
        my $diff         = {};
        foreach my $field (@valid_fields) {
            if ($c->request_parameters->{$field}) {
                $doughflow_address_diff->$field($c->request_parameters->{$field});
            }
            $diff->{$field} = $doughflow_address_diff->$field;
        }

        my $diff_helper = BOM::Platform::Helper::Model::DoughFlowAddressDiff->new({db => $connection_builder->db});
        my $create_CIL = $diff_helper->record_diff_and_determine_CIL($client->loginid, $doughflow_address_diff);

        my $result;
        if ($create_CIL) {
            my $address_mash;
            my $addresses = $diff_helper->fetch_diff_records_for_loginid($client->loginid);
            for my $address (@$addresses) {
                $address_mash .= "Address Record:\n";
                $address_mash .= $address->street . "\n";
                $address_mash .= $address->city . "\n";
                $address_mash .= $address->province . "\n";
                $address_mash .= $address->country . "\n";
                $address_mash .= $address->pcode . "\n";
            }

            $client->add_note('DOUGHFLOW_ADDRESS_MISMATCH',
                "Record Type: Client has used different addresses in DoughFlow (details in comments),  Comments:" . $address_mash);

            $result = {client_loginid => $client->loginid};
        }

        return {
            diff        => $diff,
            cil_created => $create_CIL,
            cil_result  => $result,
        };
    }
    catch {
        return $c->status_bad_request("Invalid address_diff_POST request");
    };
}

no Moo;

1;
