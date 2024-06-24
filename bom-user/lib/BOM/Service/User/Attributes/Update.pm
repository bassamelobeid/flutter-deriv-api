package BOM::Service::User::Attributes::Update;

use strict;
use warnings;
no indirect;

use Cache::LRU;
use Time::HiRes qw(gettimeofday tv_interval);

use BOM::Service;
use BOM::Service::Helpers;
use BOM::Service::User::Attributes;
use BOM::Service::User::Attributes::Get;
use BOM::Service::User::Attributes::Update::SaveHandlersClient;
use BOM::Service::User::Attributes::Update::SaveHandlersUser;
use BOM::Service::User::Attributes::Update::FinaliseHandlers;
use BOM::Service::User::Transitional::Password;
use BOM::Service::User::Transitional::SocialSignup;
use BOM::Service::User::Transitional::TotpFields;
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::Platform::Event::Emitter;

# A word to the wise on Clients objects vs User objects. The Client object appears a full on rose
# object with all the bells and whistles, and so we should use the getters/setters to ensure the
# object is aware of the changes. The User object is a bit of a kludge and in that case the hash
# access is the way to go.

# A regular expression for validate all kind of passwords
# the regex checks password is:
# - between 8 and 25 characters
# - includes at least 1 character of numbers and alphabet (both lower and uppercase)
# - all characters ASCII index should be within ( )[space] to (~)[tilde] indexes range
use constant {
    REGEX_PASSWORD_VALIDATION => qr/^(?=.*[a-z])(?=.*[0-9])(?=.*[A-Z])[ -~]{8,25}$/,
    NX_FALSE                  => 0,
    NX_TRUE                   => 1,
    FORCE_FALSE               => 0,
    FORCE_TRUE                => 1,
};

=head1 DESCRIPTION

This module provides methods to update user attributes. It includes methods to set and save various user attributes such as email, password, preferred language, trading password, and more. It also includes methods to handle specific attribute updates and save handlers for different attributes.

The module uses a regular expression to validate passwords, ensuring they are between 8 and 25 characters, include at least one character of numbers and alphabet (both lower and uppercase), and all characters ASCII index should be within ( )[space] to (~)[tilde] indexes range.

The module also includes a map of save handlers for different attributes. Not everything will have a save handler, if save is a single field then it will be saved in the set handler. If the writing to the DB via updater is more complex with multiple fields then we use the save handler to make sure we only trigger a save after all fields have been set in the request.
=cut

# Note not everthing will have a save handler, if save is a single field then it will be saved in the
# set handler. If the writing to the DB via updater is more complex with multiple fields then we use the
# save handler to make sure we only trigger a save after all fields have been set in the request
my %save_handler_map = (
    client                      => \&BOM::Service::User::Attributes::Update::SaveHandlersClient::save_client,
    client_financial_assessment => \&BOM::Service::User::Attributes::Update::SaveHandlersClient::save_client_financial_assessment,

    user_phone_number_verified => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_phone_number_verified,
    user_preferred_language    => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_preferred_language,
    user_password              => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_password,
    user_email                 => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_email,
    user_email_consent         => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_email_consent,
    user_email_verified        => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_email_verified,
    user_dx_trading_password   => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_dx_trading_password,
    user_trading_password      => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_trading_password,
    user_totp_fields           => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_totp_fields,
    user_has_social_signup     => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_has_social_signup,
    user_feature_flags         => \&BOM::Service::User::Attributes::Update::SaveHandlersUser::save_user_feature_flags,
);

my %finalise_handler_map = (
    poi_check   => \&BOM::Service::User::Attributes::Update::FinaliseHandlers::poi_check,
    onfido_sync => \&BOM::Service::User::Attributes::Update::FinaliseHandlers::onfido_sync,

    user_password => \&BOM::Service::User::Attributes::Update::FinaliseHandlers::user_password,
    user_email    => \&BOM::Service::User::Attributes::Update::FinaliseHandlers::user_email,
);

=head2 update_attributes

This subroutine acts as a wrapper for calling the internal _update_attributes with a specific behavior. It updates the attributes of an object based on the provided request but does not enforce exclusivity in attribute updating.

=over 4

=item * Input: HashRef (request) - A reference to a hash containing the attributes to be updated.

=item * Return: HashRef - Returns the result from the _update_attributes subroutine, including the status, command, and list of affected items. This call allows existing attributes to be overwritten.

=back

=cut

sub update_attributes {
    my ($request) = @_;
    return _update_attributes(FORCE_FALSE, NX_FALSE, $request);
}

=head2 update_attributes_nx

This subroutine wraps the call to the internal _update_attributes with a behavior that ensures no existing attributes are overwritten during the update. It is used to update attributes of an object based on the provided request, with a constraint that the update should not affect existing values.

=over 4

=item * Input: HashRef (request) - A reference to a hash containing the attributes to be updated.

=item * Return: HashRef - Returns the result from the _update_attributes subroutine, including the status, command, and list of affected items. This call prevents existing attributes from being overwritten.

=back

=cut

sub update_attributes_nx {
    my ($request) = @_;
    return _update_attributes(FORCE_FALSE, NX_TRUE, $request);
}

=head2 update_attributes_force

This subroutine wraps the call to the internal _update_attributes with a behavior that ignores the immutable attributes logic and overwrites as requested. Ideally this should only be used in tests and the backoffice and is likely to be enfoced by the tokens

=over 4

=item * Input: HashRef (request) - A reference to a hash containing the attributes to be updated.

=item * Return: HashRef - Returns the result from the _update_attributes subroutine, including the status, command, and list of affected items. This call prevents existing attributes from being overwritten.

=back

=cut

sub update_attributes_force {
    my ($request) = @_;
    return _update_attributes(FORCE_TRUE, NX_FALSE, $request);
}

=head2 _update_attributes

This subroutine updates the attributes of a user or client. It first checks if the caller is within the BOM::Service namespace. Then, it retrieves the attributes to be updated from the request. If no attributes are specified, it retrieves all attributes.

For each attribute, it checks if there are any flags and if they are present. If the attribute is immutable and not in force mode, it throws an error. Then, it processes each attribute, executing the set handler for the attribute and checking if anything has changed. If something has changed, it adds the save handlers and affected items to the respective lists.

After all attributes have been processed, it executes the save handlers for the attributes that have changed. Finally, it returns a hash reference containing the status, command and the list of affected items.

=over 4

=item * Input: Boolean(force_flag), Boolean(nx_flag), HashRef (request, containing attributes to be changed)

=item * Return: HashRef (status, command, affected)

=back

=cut

sub _update_attributes {
    my ($force_flag, $nx_flag, $request) = @_;
    my $attributes = $request->{attributes} // [];
    my $parameters = [];

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to BOM::Service::update_attributes not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    die "Attribute parameters must be an array reference" unless ref $attributes eq "HASH";

    if (keys %$attributes == 0) {
        $parameters = BOM::Service::User::Attributes::get_all_attributes();
    } else {
        $parameters = BOM::Service::User::Attributes::get_requested_attributes([keys %{$attributes}]);
    }

    my %requested_saves  = ();
    my %requested_finals = ();
    my @affected         = ();
    if (keys %$parameters) {
        # Before we start we should check out if any attributes have flags and if they are present
        for my $attribute (keys %$parameters) {
            my $attribute_handler = $parameters->{$attribute};
            if (defined $attribute_handler->{flags}) {
                for my $flag (keys %{$attribute_handler->{flags}}) {
                    if (!exists $request->{flags}->{$flag}) {
                        die "Missing flag: $flag";
                    }
                    #  If the flag value is an array then check if the value is in the array
                    if (ref $attribute_handler->{flags}->{$flag} eq 'ARRAY') {
                        if (!grep { $_ eq $request->{flags}->{$flag} } @{$attribute_handler->{flags}->{$flag}}) {
                            die "Invalid flag value: $flag, allowed values: " . join(", ", @{$attribute_handler->{flags}->{$flag}});
                        }
                    }
                }
            }
        }

        # Some attributes are immutable and cannot be changed but its ...variable
        unless ($force_flag) {
            # It will already have been checked if an attribute is set/unset and matched so if we
            # see it then its not allowed to be set and fail straight away
            my $immutable_attributes = BOM::Service::User::Attributes::Get::get_immutable_attributes($request, 'immutable_attributes');
            for my $attribute (keys %$parameters) {
                # Check each attribute against the immutable list, if it is immutable and already set then
                # we should throw an error, if its unset we will allow setting it, there is little point in
                # an immutable and unset attribute
                if (grep { $_ eq $attribute } @$immutable_attributes) {
                    die "Immutable|::|Attribute $attribute is immutable";
                }
            }
        }

        # Now we can start processing the attributes, the only reason to sort here is to make
        # things deterministic in terms of emitted events, it makes it easier to test if we
        # know the order of the events.
        for my $attribute (sort keys %$parameters) {
            my $attribute_handler = $parameters->{$attribute};
            my $value             = $request->{attributes}->{$attribute};

            # Handle the not_exist scenario, if not_exist is set we must read the value and
            # only save if it is not defined
            if (   !$nx_flag
                || !defined $attribute_handler->{get_handler}->($request, $attribute_handler->{remap} // $attribute, $attribute_handler->{type}))
            {
                # Execute the handler for the attribute
                my $result =
                    $attribute_handler->{set_handler}->($request, $attribute_handler->{remap} // $attribute, $attribute_handler->{type}, $value);
                # Might be nothing changed, in which case no result returned
                if (defined $result) {
                    if (defined $result->{save_handlers}) {
                        foreach my $item (@{$result->{save_handlers}}) {
                            $requested_saves{$item} = 1;
                        }
                    }
                    if (defined $result->{affected}) {
                        foreach my $item (@{$result->{affected}}) {
                            push @affected, $item;
                        }
                    }
                    if (defined $result->{finalise_handlers}) {
                        foreach my $item (@{$result->{finalise_handlers}}) {
                            $requested_finals{$item} = 1;
                        }
                    }
                }
            }
        }
    } else {
        die "No valid attributes found";
    }

    # Note to the reader, any data outside the base user/client tables may be saved directly in
    # the set handler. This is to avoid the overhead of loading the user/client object and saving
    # it for every attribute touch. This is a tradeoff between performance and consistency.

    # We are guaranteed that the user and client objects are in the cache because correlation_id
    for my $save_handler (sort keys %requested_saves) {
        die "Invalid save handler: $save_handler" if (!exists $save_handler_map{$save_handler});
        $save_handler_map{$save_handler}->($request);
    }
    for my $final_handler (sort keys %requested_finals) {
        die "Invalid finalise handler: $final_handler" if (!exists $finalise_handler_map{$final_handler});
        $finalise_handler_map{$final_handler}->($request);
    }

    return {
        status   => 'ok',
        command  => $request->{command},
        affected => \@affected
    };
}

=head2 set_client_data

This subroutine sets the data for a client. It first gets the client object using the user_id and correlation_id from the request. Then, it checks if the value of the attribute has changed. If it has, it sets the new value for the attribute and returns a hash reference containing the save handlers and the affected attribute.

Note: This is ROSE behind the client and so how you get the member value is critical to IF rose will detect its changed and update the row when you call 'save'. $client->$attribute will set the value but rose will NOT detect the change. $client->$attribute($value) will set the value and rose WILL detect the change.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: HashRef (save_handlers, finalise_handlers, affected) or undef if no change

=back

=cut

sub set_client_data {
    my ($request, $attribute, $type, $value) = @_;
    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    if (_value_has_changed($client->$attribute, $value, $type)) {
        my @handlers = ('client');
        my @affected = ();
        my @finalise = ();

        # Special cases, salutation, removed from the set_settings endpoint
        if ($attribute eq 'salutation') {
            my $updated_gender = (uc $value eq 'MR') ? 'm' : 'f';
            $client->gender($updated_gender);
            push @affected, 'gender';
        }

        # Special cases, tin_approved_time, removed from the set_settings endpoint
        # As per CRS/FATCA regulatory requirement we need to
        # save this information as client status, so updating
        # tax residence and tax number will create client status
        # as we have database trigger for that now
        if ($attribute eq 'tax_identification_number') {
            $client->tin_approved_time(undef);
            push @affected, 'tin_approved_time';
        }

        # Special cases, poi, removed from the set_settings endpoint, if the user changes one of these
        # fields we need to check the rules and sync the details with onfido, but not virtual, client
        # can only ever be virtual IF there is no real client so its a safe test.
        if (!$client->is_virtual() && grep { $_ eq $attribute } qw(first_name last_name date_of_birth)) {
            push @finalise, 'poi_check';
        }
        if (!$client->is_virtual()) {
            push @finalise, 'onfido_sync';
        }

        # Important note that this is ROSE behind the client and so how you get the member value
        # is critical to IF rose will detect its changed and update the row when you call 'save'
        # $client->$attribute         => This will set the value but rose will NOT detect the change
        # $client->$attribute($value) => This will set the value and rose WILL detect the change
        # That was a 2 hour lesson in debugging why the client wasn't saving.
        $client->$attribute($value);
        push @affected, $attribute;

        return {
            save_handlers     => \@handlers,
            finalise_handlers => \@finalise,
            affected          => \@affected
        };
    }
    return undef;
}

=head2 set_financial_assessment

This subroutine sets the financial assessment data for the default client and returns the handlers/affected status

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: Currently, it does not return anything and throws an error stating it's not implemented.

=back

=cut

sub set_financial_assessment {
    my ($request, $attribute, $type, $value) = @_;
    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    if (_value_has_changed($client->{$attribute}, $value, $type)) {
        $client->{$attribute} = $value;
        return {
            save_handlers     => [qw(client_financial_assessment)],
            finalise_handlers => [],
            affected          => [$attribute]};
    }
    return undef;
}

=head2 set_user_email

This subroutine sets the email for a user. It first gets the user object using the user_id and correlation_id from the request. Then, it checks if the value of the email attribute has changed. If it has, it sets the new email for the user and returns a hash reference containing the save handlers and the affected attribute.

If the attribute is 'email' and the user has social signup, it sets the 'has_social_signup' attribute to false and adds 'user_has_social_signup' to the save handlers. The 'user_email' is added to the save handlers. If the attribute is not 'email', 'user_email_fields' is added to the save handlers.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: HashRef (save_handlers, finalise_handlers, affected) or undef if no change

=back

=cut

sub set_user_email {
    my ($request, $attribute, $type, $value) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    if (_value_has_changed($user->{$attribute}, $value, $type)) {
        my @affected = ();
        my @handlers = ();
        my @finalise = ();

        $user->{$attribute} = $value;
        push @affected, $attribute;

        if ($attribute eq 'email') {
            if ($user->has_social_signup) {
                my $result = set_user_has_social_signup($request, 'has_social_signup', 'bool', 0);
                if (defined $result) {
                    push @affected, $result->{affected};
                    push @handlers, 'user_has_social_signup';
                }
            }
            push @handlers, 'user_email';
            push @finalise, 'user_email';
        } elsif ($attribute eq 'email_consent') {
            push @handlers, 'user_email_consent';
        } elsif ($attribute eq 'email_verified') {
            push @handlers, 'user_email_verified';
        } else {
            die "DeveloperError|::|Invalid attribute: $attribute passed to set_user_email";
        }
        return {
            save_handlers     => \@handlers,
            finalise_handlers => \@finalise,
            affected          => \@affected
        };
    }
    return undef;
}

=head2 set_user_dx_trading_password

This subroutine sets the DX trading password for a user. It first gets the user object using the user_id and correlation_id from the request. Then, it checks if the value of the DX trading password attribute has changed. If it has, it sets the new DX trading password for the user and returns a hash reference containing the save handlers and the affected attribute.

Note: The function will update the field value. If the new value is undefined, it throws an error stating that the DX trading password cannot be erased.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: HashRef (save_handlers, finalise_handlers, affected) or undef if no change

=back

=cut

sub set_user_dx_trading_password {
    my ($request, $attribute, $type, $value) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    if (_value_has_changed($user->{$attribute}, $value, $type)) {
        # The function will update the field value
        # TODO - Move that code in here
        if (defined $value) {
            $user->{$attribute} = $value;
            return {
                save_handlers     => [qw(user_dx_trading_password)],
                finalise_handlers => [],
                affected          => [$attribute]};
        } else {
            die "set_user_dx_trading_password: Cannot erase trading password";
        }
    }
    return undef;
}

=head2 set_user_trading_password

This subroutine sets the trading password for a user. It first gets the user object using the user_id and correlation_id from the request. Then, it checks if the value of the trading password attribute has changed. If it has, it sets the new trading password for the user and returns a hash reference containing the save handlers and the affected attribute.

Note: The function will update the field value. If the new value is undefined, it throws an error stating that the trading password cannot be erased.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: HashRef (save_handlers, finalise_handlers, affected) or undef if no change

=back

=cut

sub set_user_trading_password {
    my ($request, $attribute, $type, $value) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    if (_value_has_changed($user->{$attribute}, $value, $type)) {
        # The function will update the field value
        # TODO - Move that code in here
        if (defined $value) {
            $user->{$attribute} = $value;
            return {
                save_handlers     => [qw(user_trading_password)],
                finalise_handlers => [],
                affected          => [$attribute]};
        } else {
            die "set_user_trading_password: Cannot erase trading password";
        }
    }
    return undef;
}

=head2 set_user_has_social_signup

This subroutine sets the social signup status for a user. It first gets the user object using the user_id and correlation_id from the request. Then, it checks if the value of the 'has_social_signup' attribute has changed. If it has, it updates the 'has_social_signup' status for the user.

If the new value is false, it removes all other social accounts connected to the user. Finally, it returns a hash reference containing the save handlers and the affected attribute if a change was made, or undef if no change was detected.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: HashRef (save_handlers, finalise_handlers, affected) or undef if no change

=back

=cut

sub set_user_has_social_signup {
    my ($request, $attribute, $type, $value) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    if (_value_has_changed($user->{$attribute}, $value, $type)) {
        $user->{$attribute} = $value;
        return {
            save_handlers     => [qw(user_has_social_signup)],
            finalise_handlers => [],
            affected          => [$attribute]};
    }
    return undef;
}

=head2 set_user_totp_fields

This subroutine sets the Time-based One-Time Password (TOTP) fields for a user. It first gets the user object using the user_id and correlation_id from the request. Then, it checks if the value of the TOTP attribute has changed. If it has, it sets the new value for the TOTP attribute and returns a hash reference containing the save handlers and the affected attribute.

Note: There is a consideration to move the setting of the attribute to the save handler to handle "on-change" of 'is_totp_enabled' and trash some tokens.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: HashRef (save_handlers, finalise_handlers, affected) or undef if no change

=back

=cut

sub set_user_totp_fields {
    my ($request, $attribute, $type, $value) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    # TODO: Note might be better of NOT setting here but in the save handler we need to do an
    # TODO: "on-change" handling of is_totp_enabled and trash some tokens.
    if (_value_has_changed($user->{$attribute}, $value, $type)) {
        $user->{$attribute} = $value;
        return {
            save_handlers     => [qw(user_totp_fields)],
            finalise_handlers => [],
            affected          => [$attribute]};
    }
    return undef;
}

=head2 set_user_phone_number_verified

This subroutine is currently not implemented. It is intended to set the phone number verification status for a user.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: Currently, it does not return anything and throws an error stating it's not implemented.

=back

=cut

sub set_user_phone_number_verified {
    my ($request, $attribute, $type, $value) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    if (_value_has_changed($user->{$attribute}, $value, $type)) {
        $user->{$attribute} = $value;
        return {
            save_handlers     => [qw(user_phone_number_verified)],
            finalise_handlers => [],
            affected          => [$attribute]};
    }
    return undef;
}

=head2 set_user_password

This subroutine sets the password for a user. It first gets the user object using the user_id and correlation_id from the request. Then, it checks if the value of the password attribute has changed. If it has, it sets the new password for the user and returns a hash reference containing the save handlers and the affected attribute.

The function performs several checks before setting the new password:
- If the new password is undefined, it throws an error stating that the password cannot be erased.
- If the 'password_update_reason' flag is not defined in the request, it throws an error.
- If the 'password_previous' flag is defined, it checks if the old password is correct and if the new password is different from the old one.
- If the new password is the same as the user's email, it throws an error.
- If the new password does not meet the password validation criteria, it throws an error.

If the 'password_update_reason' flag is set to 'reset_password' and the user has social signup, it sets the 'has_social_signup' attribute to false.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: HashRef (save_handlers, finalise_handlers, affected) or undef if no change

=back

=cut

sub set_user_password {
    my ($request, $attribute, $type, $value) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    if (_value_has_changed($user->{$attribute}, $value, $type)) {

        if (!defined $value) {
            die "set_user_password: Cannot erase password";
        } elsif (!defined $request->{flags} && !defined $request->{password_update_reason}) {
            die 'set_user_password: Missing request parameter password_update_reason' unless defined $request->{update_password_reason};
        } else {
            my $hash_pw = BOM::Service::User::Transitional::Password::hashpw($value);

            # Roll up, roll up, get your password validation here....
            if (defined $request->{flags}->{password_previous} && $request->{flags}->{password_previous} ne '') {
                my $old_password = $request->{flags}->{password_previous};

                if (!BOM::Service::User::Transitional::Password::checkpw($old_password, $user->password)) {
                    die "PasswordError|::|That password is incorrect. Please try again.";
                }
                if ($value eq $old_password) {
                    die "PasswordError|::|Current password and new password cannot be the same.";
                }
            }

            if (lc $value eq lc $user->email) {
                die "PasswordError|::|You cannot use your email address as your password.";
            }

            if ($value !~ REGEX_PASSWORD_VALIDATION) {
                die "PasswordError|::|Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.";
            }

            $user->{$attribute} = $hash_pw;

            my @affected = ('password');
            my @handlers = ('user_password');
            my @finalise = ('user_password');

            my $reason = $request->{flags}->{password_update_reason};
            if ($reason eq 'reset_password' && $user->{has_social_signup}) {
                my $result = set_user_has_social_signup($request, 'has_social_signup', 'bool', 0);
                if (defined $result) {
                    push @affected, $result->{affected};
                    push @handlers, 'user_has_social_signup';
                }
            }

            return {
                save_handlers     => \@handlers,
                finalise_handlers => \@finalise,
                affected          => \@affected
            };
        }
    }
    return undef;
}

=head2 set_user_preferred_language

This subroutine sets the preferred language for a user. It first gets the user object using the user_id and correlation_id from the request. Then, it checks if the value of the preferred language attribute has changed. If it has, it sets the new preferred language for the user and returns a hash reference containing the save handlers and the affected attribute.

The function performs a regex check on the new value before setting it. The new value must be either a two-letter language code (e.g., "EN") or a combination of a two-letter language code and a two-letter country code (e.g., "EN_US"). The function converts the new value to uppercase before setting it.

If the new value does not pass the regex check, the function throws an error.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: HashRef (save_handlers, finalise_handlers, affected) or undef if no change

=back

=cut

sub set_user_preferred_language {
    my ($request, $attribute, $type, $value) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    if (_value_has_changed($user->{$attribute}, $value, $type)) {
        # Check value for consistency BEFORE we do any as there is a 'hidden' DB validation
        # we don't want to trip the signal so lets pre-validate
        if (uc($value) =~ /^[A-Z]{2}$|^[A-Z]{2}_[A-Z]{2}$/) {
            $user->{$attribute} = uc($value);
            return {
                save_handlers     => [qw(user_preferred_language)],
                finalise_handlers => [],
                affected          => [$attribute]};
        } else {
            die "set_user_preferred_language: Failed rexeg check on value: '$value'";
        }
    }
    return undef;
}

=head2 set_accepted_tnc_version

This subroutine is currently not implemented. It is intended to set the accepted Terms and Conditions version for a user.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: Currently, it does not return anything and throws an error stating it's not implemented.

=back

=cut

sub set_accepted_tnc_version {
    die "set_accepted_tnc_version: Not implemented";
}

=head2 set_feature_flags

This subroutine is currently not implemented. It is intended to set the feature flag for a user.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: Currently, it does not return anything and throws an error stating it's not implemented.

=back

=cut

sub set_feature_flags {
    my ($request, $attribute, $type, $value) = @_;
    if (_value_has_changed(BOM::Service::User::Attributes::Get::get_feature_flags($request, $attribute, $type), $value, $type)) {
        return {
            save_handlers     => [qw(user_feature_flags)],
            finalise_handlers => [],
            affected          => [$attribute]};
    } else {
        return undef;
    }
}

=head2 set_immutable_attributes

This subroutine is not allowed to be used. It is intended to set the immutable attributes for a user, but due to the nature of these attributes being immutable, the operation is not permitted.

=over 4

=item * Input: HashRef (request), String (attribute), String (type), Scalar (value)

=item * Return: Currently, it does not return anything and throws an error stating it's not allowed.

=back

=cut

sub set_immutable_attributes {
    die "set_immutable_attributes: Not allowed";
}

=head2 set_not_supported

This subroutine is used when an attempt is made to set an attribute that is not supported. It immediately throws an error stating that setting of the attribute is not supported.

=over 4

=item * Input: None

=item * Return: Does not return a value. Instead, it throws an error.

=back

=cut

sub set_not_supported {
    die "Setting of this attributed is not supported";
}

=head2 _value_has_changed

This subroutine checks if two values have changed based on their type. It first checks if both values are undefined, in which case it returns 0 (indicating no change). If one value is defined and the other is not, it returns 1 (indicating a change).

Then, it performs type-specific comparisons. If the type is 'string', it checks if the values are not equal. If the type is 'bool', it checks if the boolean representations of the values are not equal. If the type is 'number', it checks if the numeric representations of the values are not equal.

If the type is not supported, it throws an error.

=over 4

=item * Input: Scalar (value1), Scalar (value2), String (type)

=item * Return: 1 if the values have changed, 0 otherwise. Dies if the type is not supported.

=back

=cut

sub _value_has_changed {
    my ($value1, $value2, $type) = @_;
    # Ensure we treat undef values as not differing when both are undef
    return 0 if !defined $value1 && !defined $value2;
    # Handle undef values consistently across types
    return 1 if (!defined $value1 && defined $value2) || (defined $value1 && !defined $value2);
    # Type-specific comparisons
    if ($type eq 'string' || $type eq 'string-nullable') {
        return $value1 ne $value2 ? 1 : 0;
    } elsif ($type eq 'bool' || $type eq 'bool-nullable') {
        return (!!$value1 != !!$value2) ? 1 : 0;
    } elsif ($type eq 'number') {
        return ($value1 != $value2) ? 1 : 0;
    } elsif ($type eq 'json') {
        # Compare top level keys and values
        return (keys %$value1 != keys %$value2 || grep { !exists $value2->{$_} || $value1->{$_} ne $value2->{$_} } keys %$value1);
    } else {
        die "if_values_differ, unsupported type: $type.";
    }
}

1;
