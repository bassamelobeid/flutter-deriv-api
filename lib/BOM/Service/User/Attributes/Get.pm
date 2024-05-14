package BOM::Service::User::Attributes::Get;

use strict;
use warnings;
no indirect;

use Cache::LRU;
use Time::HiRes qw(gettimeofday tv_interval);
use Text::Trim  qw(trim);
use BOM::Service;
use BOM::Service::User::Attributes;
use BOM::Service::Helpers;
use BOM::User;

=head1 NAME

BOM::Service::User::Attributes::Get

=head1 DESCRIPTION

This package provides methods to get various user attributes. It includes methods to get attributes such as client data, user data, accepted terms and conditions version, user phone number verification status, financial assessment, feature flag, immutable attributes, user UUID, and user ID.

=cut

=head2 get_attributes

This subroutine takes a request as input and returns a hash reference containing the status, command, request ID, and requested attributes. The attributes are retrieved based on the attribute handlers defined in the parameters. If no attributes are specified in the request, all attributes are retrieved. If the attribute parameters are not an array reference, or if no valid attributes are found, the subroutine dies with an error message.

=over 4

=item * Input: HashRef (request)

=item * Return: HashRef (hash reference containing the status, command, request ID, and requested attributes)

=back

=cut

sub get_attributes {
    my ($request)   = @_;
    my $attributes  = $request->{attributes} // [];
    my %return_data = ();
    my $parameters  = [];

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to BOM::Service::get_attributes not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    die "Attribute parameters must be an array reference" unless ref $attributes eq "ARRAY";

    if (scalar @$attributes == 0) {
        $parameters = BOM::Service::User::Attributes::get_all_attributes();
    } else {
        $parameters = BOM::Service::User::Attributes::get_requested_attributes($attributes);
    }

    if (keys %$parameters) {
        for my $attribute (keys %$parameters) {
            my $attribute_handler = $parameters->{$attribute};
            # Execute the handler for the attribute
            $return_data{$attribute} =
                $attribute_handler->{get_handler}->($request, $attribute_handler->{remap} // $attribute, $attribute_handler->{type});
        }
    } else {
        die "No valid attributes found";
    }

    return {
        status     => 'ok',
        command    => $request->{command},
        attributes => \%return_data
    };
}

=head2 get_client_data

This subroutine retrieves specific client data based on the attribute and type provided. It first gets the client object using the user_id and correlation_id from the request. Then, depending on the type, it returns the attribute value. If the type is 'string', it trims and returns the attribute value. If the type is 'bool', it returns the attribute value or 0 if the attribute is not defined. For any other type, it directly returns the attribute value.

=over 4

=item * Input: HashRef (request), String (attribute), String (type)

=item * Return: Varies (the attribute value from the client object, based on the type)

=back

=cut

sub get_client_data {
    my ($request, $attribute, $type) = @_;
    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    if ($type eq 'string') {
        return trim($client->$attribute);
    } elsif ($type eq 'bool') {
        return $client->$attribute // 0;
    } elsif ($type eq 'bool-nullable') {
        return $client->$attribute;
    } else {
        return $client->$attribute;
    }
}

=head2 get_user_data

This subroutine retrieves specific user data based on the attribute and type provided. It first gets the user object using the user_id and correlation_id from the request. Then, depending on the type, it returns the attribute value. If the type is 'string', it trims and returns the attribute value. If the type is 'bool', it returns the attribute value or 0 if the attribute is not defined. For any other type, it directly returns the attribute value.

=over 4

=item * Input: HashRef (request), String (attribute), String (type)

=item * Return: Varies (the attribute value from the user object, based on the type)

=back

=cut

sub get_user_data {
    my ($request, $attribute, $type) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    if ($type eq 'string') {
        return trim($user->{$attribute});
    } elsif ($type eq 'bool') {
        return $user->{$attribute} // 0;
    } elsif ($type eq 'bool-nullable') {
        return $user->{$attribute};
    } else {
        return $user->{$attribute};
    }
}

=head2 get_accepted_tnc_version

This subroutine retrieves the version of the terms and conditions that the user has accepted. It first gets the user object using the user_id and correlation_id from the request. Then, it queries the database to get the version of the terms and conditions that the user has accepted. If the user has not accepted any terms and conditions, it returns an empty string.

=over 4

=item * Input: HashRef (request), String (attribute), String (type)

=item * Return: String (version of the accepted terms and conditions) or an empty string if the user has not accepted any terms and conditions

=back

=cut

sub get_accepted_tnc_version {
    my ($request, $attribute, $type) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});

    return $user->dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT version FROM users.get_tnc_approval(?, ?) LIMIT 1',
                undef, $user->id, BOM::Platform::Context::request()->brand->name);
        }) // '';
}

=head2 get_user_phone_number_verification

This subroutine retrieves the verification status of the user's phone number. It first gets the user object using the user_id and correlation_id from the request. Then, it returns a hash reference containing the verification status and the next attempt time (if defined).

=over 4

=item * Input: HashRef (request), String (attribute), String (type)

=item * Return: HashRef (hash reference containing the verification status and the next attempt time)

=back

=cut

sub get_user_phone_number_verification {
    my ($request, $attribute, $type) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});

    return {
        verified => $user->pnv->verified,
        defined $user->pnv->next_attempt ? (next_attempt => $user->pnv->next_attempt) : (),
    };
}

=head2 get_financial_assessment

This subroutine retrieves the financial assessment of a client. It first gets the client object using the user_id and correlation_id from the request. Then, it decodes the financial assessment of the client and returns it.

=over 4

=item * Input: HashRef (request), String (attribute), String (type)

=item * Return: Decoded financial assessment of the client

=back

=cut

sub get_financial_assessment {
    my ($request, $attribute, $type) = @_;
    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    return BOM::User::FinancialAssessment::decode_fa($client->financial_assessment);
}

=head2 get_feature_flag

This subroutine retrieves the feature flag of a user. It first gets the user object using the user_id and correlation_id from the request. Then, it returns the feature flag of the user.

=over 4

=item * Input: HashRef (request), String (attribute), String (type)

=item * Return: Feature flag of the user

=back

=cut

sub get_feature_flag {
    my ($request, $attribute, $type) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    return $user->get_feature_flag();
}

=head2 get_immutable_attributes

This subroutine retrieves the immutable attributes of a client. It first gets the client object using the user_id and correlation_id from the request. Then, it retrieves the immutable fields of the client and returns them as an array reference.

=over 4

=item * Input: HashRef (request), String (attribute), String (type)

=item * Return: ArrayRef (immutable fields of the client)

=back

=cut

sub get_immutable_attributes {
    my ($request, $attribute, $type) = @_;
    my $client           = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    my @immutable_fields = $client->immutable_fields();
    return \@immutable_fields;
}

=head2 get_user_uuid

This subroutine retrieves the UUID of a user. It first gets the user object using the user_id and correlation_id from the request. Then, it converts the user's id to a UUID and returns it.

=over 4

=item * Input: HashRef (request), String (attribute), String (type)

=item * Return: UUID of the user

=back

=cut

sub get_user_uuid {
    my ($request, $attribute, $type) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    return BOM::Service::Helpers::binary_user_id_to_uuid($user->id);
}

=head2 get_user_id

This subroutine retrieves the ID of a user. It first gets the user object using the user_id and correlation_id from the request. Then, it returns the user's ID.

=over 4

=item * Input: HashRef (request), String (attribute), String (type)

=item * Return: User's ID

=back

=cut

sub get_user_id {
    my ($request, $attribute, $type) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    return $user->id;
}

1;
