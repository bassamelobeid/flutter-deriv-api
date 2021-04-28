package BOM::User::Client::PaymentAgent;

use strict;
use warnings;

use BOM::User::Client;
use BOM::User;
use BOM::Database::DataMapper::PaymentAgent;
use BOM::Platform::Context qw(localize);

use Brands;
use List::MoreUtils qw(all);
use Scalar::Util qw(looks_like_number);
use base 'BOM::Database::AutoGenerated::Rose::PaymentAgent';
## VERSION

use constant MAX_PA_COMMISSION => 9;

# By drawing on Client's constructor we first prove the
# client record exists and we also benefit from the
# broker-savvy db connection handling there.
sub new {
    my ($class, @args) = @_;
    my $client = BOM::User::Client->new(@args) || return undef;
    my $self   = $client->payment_agent        || return undef;
    return bless $self, $class;
}

# Save to default writable place, unless explicitly set by caller..
sub save {
    my ($self, %args) = @_;
    $self->set_db(delete($args{set_db}) || 'write');
    return $self->SUPER::save(%args);
}

# Promote my client pointer to the smarter version of client..
# There are 2 versions of client, One is BOM::Database::AutoGenerated::Rose::Client, which will be returned if we don't overwrite the sub client here.
# Another is the BOM::User::Client, which is a smarter one and is a subclass of the previous one. Here we overwrite this sub to return the smarter one.
# TODO: will fix it when we remove Rose:DB::Object
sub client {
    my $self = shift;
    return bless $self->SUPER::client, 'BOM::User::Client';
}

=head2 get_payment_agents

Will deliver the list of payment agents based on the provided country, currency and broker code.

Takes the following parameters:

=over 4

=item C<$country_code> - L<2-character ISO country code|https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2> to restrict search (agents with no country will not be included)

=item C<$broker_code> - Two letter representation of broker. For example CR.

=item C<$currency> - Three letter currency code. For example USD.

=item C<$is_listed> - Indicate which payment agents you want to retrieve. whether they appear on binary site or not or both. For example ('t','f', NULL)

=back

Returns a  list of C<BOM::User::Client::PaymentAgent> objects.

=cut

sub get_payment_agents {
    my ($self, %args) = @_;

    my ($country_code, $broker_code, $currency, $is_listed) = @args{qw/ country_code broker_code currency is_listed/};

    die "Broker code should be specified" unless (defined($country_code) and defined($broker_code));
    my %query_args = (
        target_country => $country_code,
        is_listed      => $is_listed
    );
    $query_args{currency_code} = $currency if $currency;
    my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $broker_code});
    return $payment_agent_mapper->get_authenticated_payment_agents(%query_args);
}

=head2 set_countries

save countries against a payment agent

=over 4

=item C<@target_countries> - Array of country codes L<2-character ISO country code|https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2>

=back

Returns 1

=cut

sub set_countries {
    my $self             = shift;
    my $target_countries = shift;
    my $login_id         = $self->client_loginid;

    my @suspended_countries = grep { BOM::User::is_payment_agents_suspended_in_country($_) } @$target_countries;
    return undef if (@suspended_countries);

    return undef unless ($self->_validate_country_code($target_countries));

    return undef unless ($self->_validate_same_landing_company($target_countries));

    $self->db->dbic->run(
        fixup => sub {
            my $authenticated_payment_agents_statement = $_->prepare("SELECT * FROM betonmarkets.set_payment_agent_countries(?,?)");
            $authenticated_payment_agents_statement->execute($login_id, $target_countries);
            return $authenticated_payment_agents_statement->fetchall_arrayref;
        });
    return 1;
}

=head2 get_countries

Will deliver countries saved against particular payment agent.

Returns a arrayref of country codes saved against a payment_agent.

=cut

sub get_countries {
    my $self     = shift;
    my $login_id = $self->client_loginid;
    return $self->db->dbic->run(
        fixup => sub {
            return $_->selectcol_arrayref('SELECT country FROM betonmarkets.get_individual_payment_agent_countries(?)', undef, $login_id);
        });
}

sub _validate_country_code {
    my ($self, $target_countries) = @_;
    my $countries_instance = Brands->new()->countries_instance;
    return all { defined $countries_instance->countries->country_from_code($_) } @$target_countries;
}

sub _validate_same_landing_company {
    my ($self, $target_countries) = @_;
    my $countries_instance = Brands->new()->countries_instance;

    return all {
        ($countries_instance->real_company_for_country($_) // '') eq $self->client->landing_company->short
    }
    @$target_countries;
}

=head2 get_payment_agents_by_name

Searches for payment agentis by name (case insensitive), by taking these arguments:

=over 4

=item * name - The name to lookup.

=back

Returns an arrayref of the matching database rows.

=cut

sub get_payment_agents_by_name {
    my ($self, $name) = @_;

    return $self->client->db->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref('SELECT * FROM betonmarkets.payment_agent where lower(payment_agent_name) = ?', {Slice => {}}, lc($name));
        });
}

=head2  max_pa_commission

Returns the maximum payment agent commission.

=cut

sub max_pa_commission {
    return MAX_PA_COMMISSION;
}

=head2 validate_payment_agent_details

Validates the details of a payment agent; to be called before creating or updating a payment agent.

=over 4

=item * details - A hash of the input fields

=back

Returns the details with default values set (if mssing), ready to be saved into database.

=cut

sub validate_payment_agent_details {
    my ($self, %details) = @_;
    my $args   = \%details;
    my $client = $self->client;

    # initialze non-null fields
    $args->{$_} //= 0 for qw(is_authenticated is_listed);
    $args->{email}          ||= $client->email;
    $args->{target_country} ||= $client->residence;
    $args->{phone}          ||= $client->phone;

    my $error_sub = sub {
        my ($error_code, $fields, %extra) = @_;
        $fields = [$fields] unless ref $fields;
        return {
            code    => $error_code,
            details => {
                fields => $fields,
            },
            $extra{params}  ? (params  => $extra{params})  : (),
            $extra{message} ? (message => $extra{message}) : (),
        };
    };

    die 'PermissionDenied\n' if $client->is_virtual;
    die "NoAccountCurrency\n" unless $client->default_account;
    die "PaymentAgentsSupended\n" if BOM::User::is_payment_agents_suspended_in_country($client->residence);

    # required fields
    my @missing = grep { !$args->{$_} } qw/payment_agent_name url email phone information supported_banks/;
    push @missing, grep { not defined $args->{$_} } (qw/code_of_conduct_approval commission_deposit commission_withdrawal/);
    die $error_sub->('RequiredFieldMissing', [@missing]) if @missing;

    # COC approval
    die $error_sub->('CodeOfConductNotApproved', 'code_of_conduct_approval') unless $args->{code_of_conduct_approval};

    # duplicate name
    my $pa_list = $self->get_payment_agents_by_name($args->{payment_agent_name});
    die $error_sub->(
        'DuplicateName', 'payment_agent_name',
        message => "The name <$args->{payment_agent_name}> is already taken by $pa_list->[0]->{client_loginid}"
        )
        if $pa_list
        and $pa_list->[0]
        and $pa_list->[0]->{client_loginid} ne $client->loginid;

    my $remove_redundant_spaces = sub {
        my $value = shift // '';
        $value =~ s/^\s+|\s+$//g;
        $value =~ s/\s+/ /g;

        return $value;
    };

    # validate string fields
    my @invalid_fields;
    for (qw/payment_agent_name information/) {
        $args->{$_} = $remove_redundant_spaces->($args->{$_});
        push(@invalid_fields, $_) unless $args->{$_} =~ /\p{L}/;
    }

    my @supported_payment_methods = split ',', ($args->{supported_banks} // '');
    @supported_payment_methods = map { $remove_redundant_spaces->($_) } @supported_payment_methods;
    push(@invalid_fields, 'supported_banks')
        unless scalar @supported_payment_methods and all { $_ =~ m/\p{L}/ } @supported_payment_methods;

    die $error_sub->('InvalidStringValue', \@invalid_fields) if @invalid_fields;

    # numeric vlues
    for (qw/commission_deposit commission_withdrawal min_withdrawal max_withdrawal/) {
        $args->{$_} //= 0;
        push(@invalid_fields, $_) unless looks_like_number($args->{$_});
    }
    die $error_sub->('InvalidNumericValue', \@invalid_fields) if @invalid_fields;

    # commissions
    $args->{'commission_deposit'}    += 0;
    $args->{'commission_withdrawal'} += 0;
    for (qw/commission_deposit commission_withdrawal/) {
        push(@invalid_fields, $_) unless $args->{$_} >= 0 and $args->{$_} <= MAX_PA_COMMISSION;
    }
    die $error_sub->('ValueOutOfRange', \@invalid_fields, params => [0, MAX_PA_COMMISSION]) if @invalid_fields;

    for (qw/commission_deposit commission_withdrawal/) {
        push(@invalid_fields, $_) unless $args->{$_} =~ m/^\d(.\d{1,2})?$/;
    }
    die $error_sub->('TooManyDecimalPlaces', \@invalid_fields, params => [2]) if @invalid_fields;

    # withdrawal limits
    my $pa = $client->get_payment_agent;
    $args->{currency_code} ||= ($pa ? $pa->currency_code : undef) // $client->currency;

    my $min_max = BOM::Config::PaymentAgent::get_transfer_min_max($args->{currency_code});
    $args->{max_withdrawal} ||= $min_max->{maximum};
    $args->{min_withdrawal} ||= $min_max->{minimum};

    die $error_sub->('MinWithdrawalIsNegative', 'min_withdrawal')
        if ($args->{min_withdrawal} < 0);
    die $error_sub->('MinWithdrawalIsNegative', ['min_withdrawal', 'max_withdrawal'])
        if ($args->{max_withdrawal} < $args->{min_withdrawal});

    # let the empty optional fields get their default values
    $args->{affiliate_id}     //= '';
    $args->{summary}          //= '';
    $args->{is_listed}        //= 0;
    $args->{is_authenticated} //= 0;

    # rebuild supported_banks from array
    $args->{supported_banks} = join(',', @supported_payment_methods);

    return $args;
}

1;
