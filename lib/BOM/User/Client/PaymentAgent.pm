package BOM::User::Client::PaymentAgent;

use strict;
use warnings;

use Brands;
use List::MoreUtils                  qw(all any uniq);
use Scalar::Util                     qw(looks_like_number);
use List::Util                       qw(sum max);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use base 'BOM::Database::AutoGenerated::Rose::PaymentAgent';
use Format::Util::Numbers qw(financialrounding);

use BOM::User::Client;
use BOM::User;
use BOM::Database::DataMapper::PaymentAgent;
use BOM::Platform::Context qw(localize);

use Brands;
use List::MoreUtils qw(all none any uniq);
use Scalar::Util    qw(looks_like_number);
use JSON::MaybeUTF8 qw(encode_json_utf8);

use base 'BOM::Database::AutoGenerated::Rose::PaymentAgent';

## VERSION

use constant MAX_PA_COMMISSION => 9;
use constant RESTRICTED_SERVICES =>
    [qw(p2p cashier_withdraw trading transfer_to_pa paymentagent_withdraw mt5_deposit trading_platform_deposit transfer_to_non_pa_sibling)];

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
    die "Failed to save payment agent" unless $self->SUPER::save(%args);
    $self->_save_linked_details(%args);

    return 1;
}

=head2 details_main_field

Returns a hashref containing the name of the main field in each linked details (B<urls>, B<phone_numbers>, B<supported_payment_mehthods>).

=over 4

=item c<%args>: client details represented as a hash.

=back

=cut

sub details_main_field {
    return +{
        urls                      => 'url',
        phone_numbers             => 'phone_number',
        supported_payment_methods => 'payment_method',
    };
}

=head2 _save_linked_details

Saves payment agent's B<phone_numbers>, B<urls> and B<supprted_payment_methods> into their linked tables.
It takes on argument:

=over 4

=item c<%args>: client details represented as a hash.

=back

=cut

sub _save_linked_details {
    my ($self, %args) = @_;

    $self->db->dbic->run(
        fixup => sub {
            $_->do(
                'SELECT betonmarkets.payment_agent_update_linked_details(?, ?, ?, ?)',
                undef, $self->client_loginid, map { encode_json_utf8($args{$_} // $self->$_) } (qw/urls phone_numbers supported_payment_methods/),
            );
        });

    # reload them from database
    for my $name (qw/urls phone_numbers supported_payment_methods/) {
        my $load_method = "_load_$name";
        $self->{$name} = $self->$load_method;
    }

    return 1;
}

=head2 urls

Getter/setter for payment agent's urls. It takes one arg:

=over 4

=item C<$values> (optional) - An array of urls each element in C<{url => '..'}> form.
If this argument is missing, the function will act as a getter, returning the current values in the same structure.

=back

=cut

sub urls {
    my ($self, $values) = @_;

    return $self->_linked_details(urls => $values);
}

=head2 phone_numbers

Getter/setter for payment agent's phone numbers. It takes one arg:

=over 4

=item C<$values> (optional) - An array of phone numbers, each element in C<{phone => '..'}> form.
If this argument is missing, the function will act as a getter, returning the current values in the same structure.

=back

=cut

sub phone_numbers {
    my ($self, $values) = @_;

    return $self->_linked_details(phone_numbers => $values);
}

=head2 supported_payment_methods

Getter/setter for payment agent's supported payment methods. It takes one arg:

=over 4

=item C<$values> (optional) - An array of payment agent methods, each element in C<{payment_method => '..'}> form.
If this argument is missing, the function will act as a getter, returning the current values in the same structure.

=back

=cut

sub supported_payment_methods {
    my ($self, $values) = @_;

    return $self->_linked_details(supported_payment_methods => $values);
}

=head2 _linked_details

Get's or sets client's linked details.
It takes two arguments on argument:

=over 4

=item C<name> (required) - attribute's name (B<phone_numbers>, B<urls> or B<supprted_payment_methods>)

=item C<values> (optional) - attributes values. If this orgument is not empty, 
the values will be saved in payment agent's onject; otherwise the current value will be returned.

=back

=cut

sub _linked_details {
    my ($self, $name, $values) = @_;

    # getter
    unless (defined $values) {
        my $load_method = "_load_$name";
        $self->{$name} //= $self->$load_method;

        return $self->{$name};
    } else {
        # setter
        $self->{$name} = $values;
    }

    return $self->{$name};
}

=head2 _load_urls

Loads and returns payment agent's urls.

=cut

sub _load_urls {
    my ($self) = @_;

    return $self->db->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref(
                "SELECT url FROM betonmarkets.payment_agent_urls WHERE client_loginid = ? ORDER BY url",
                {Slice => {}},
                $self->client_loginid
            );
        });
}

=head2 _load_phone_numbers

Loads and returns payment agent's phone numbers.

=cut

sub _load_phone_numbers {
    my ($self) = @_;

    return $self->db->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref(
                "SELECT phone_number FROM betonmarkets.payment_agent_phone_numbers WHERE client_loginid = ? ORDER BY phone_number",
                {Slice => {}},
                $self->client_loginid
            );
        });
}

=head2 _load_supported_payment_methods

Loads and returns payment agent's payment methods.

=cut

sub _load_supported_payment_methods {
    my ($self) = @_;

    return $self->db->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref(
                "SELECT payment_method FROM betonmarkets.payment_agent_supported_payment_methods WHERE client_loginid = ? ORDER BY payment_method",
                {Slice => {}},
                $self->client_loginid
            );
        });
}

=head2 tier_details

Loads and returns all fields for the assigned tier.

=cut

sub tier_details {
    my ($self) = @_;

    return $self->db->dbic->run(
        fixup => sub {
            return $_->selectrow_hashref('SELECT cashier_withdraw, p2p, trading, transfer_to_pa, name FROM betonmarkets.pa_tier_list(?)',
                undef, $self->tier_id);
        });
}

# Promote my client pointer to the smarter version of client..
# There are 2 versions of client, One is BOM::Database::AutoGenerated::Rose::Client, which will be returned if we don't overwrite the sub client here.
# Another is the BOM::User::Client, which is a smarter one and is a subclass of the previous one. Here we overwrite this sub to return an instance of it.
# TODO: will fix it when we remove Rose:DB::Object
sub client {
    my ($self, $operation) = @_;

    return BOM::User::Client->get_client_instance($self->SUPER::client()->{loginid}, $operation // 'write');
}

=head2 code_of_conduct_approval_date

Converts code_of_conduct_approval_time into a string containing only the date.

=cut

sub code_of_conduct_approval_date {
    my ($self) = @_;

    return $self->code_of_conduct_approval_time ? Date::Utility->new($self->code_of_conduct_approval_time)->date_yyyymmdd : '';
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

    my $dbic    = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $broker_code})->db->dbic;
    my $db_rows = $dbic->run(
        fixup => sub {
            my $authenticated_pa_sth = $_->prepare('SELECT * FROM betonmarkets.get_payment_agents_by_country(?, ?, ?, ?)');
            $authenticated_pa_sth->execute($country_code, 't', $currency, $is_listed);

            return $authenticated_pa_sth->fetchall_hashref('client_loginid');
        });

    return {map { $_ => BOM::User::Client::PaymentAgent->new({loginid => $_}) } keys %$db_rows};
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

    return all { ($countries_instance->real_company_for_country($_) // '') eq $self->client->landing_company->short } @$target_countries;
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
    $args->{is_listed} //= 0;
    $args->{email}          ||= $client->email;
    $args->{target_country} ||= $client->residence;
    $args->{phone_numbers} //= [{phone_number => $client->phone}];
    my $skip_coc_validation = delete $args->{skip_coc_validation};

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
    my @missing = grep { !$args->{$_} } qw/payment_agent_name email information urls phone_numbers supported_payment_methods/;
    push @missing, grep { (ref($args->{$_} // '') eq 'ARRAY' && !$args->{$_}->@*) } qw/urls phone_numbers supported_payment_methods/;
    push @missing, grep { not defined $args->{$_} } (qw/code_of_conduct_approval commission_deposit commission_withdrawal/);
    die $error_sub->('RequiredFieldMissing', [uniq @missing]) if @missing;

    die $error_sub->('CodeOfConductNotApproved', 'code_of_conduct_approval')
        unless $skip_coc_validation or $args->{code_of_conduct_approval};

    # duplicate name
    for my $found_pa ($self->get_payment_agents_by_name($args->{payment_agent_name})->@*) {
        # skip clients of the same user
        next if List::Util::any { $found_pa->{client_loginid} eq $_->loginid } $client->user->clients;

        die $error_sub->(
            'DuplicateName', 'payment_agent_name',
            message => "The name <$args->{payment_agent_name}> is already taken by $found_pa->{client_loginid}"
        );
    }
    my $remove_redundant_spaces = sub {
        my $value = shift // '';
        $value =~ s/^\s+|\s+$//g;
        $value =~ s/\s+/ /g;

        return $value;
    };

    # validate string fields
    my @invalid_strings;
    my @invalid_arrays;
    for (qw/payment_agent_name information/) {
        $args->{$_} = $remove_redundant_spaces->($args->{$_});
        push(@invalid_strings, $_) unless $args->{$_} =~ /\p{L}/;
    }

    for my $field (qw/supported_payment_methods urls phone_numbers/) {
        my $element_attriblute = details_main_field->{$field};
        my @values             = eval { $args->{$field}->@* };
        # only non-empty arrays with hashref elements are accepted
        unless (scalar @values && all { ref($_) eq 'HASH' && defined $_->{$element_attriblute} } @values) {
            push @invalid_arrays, $field;
            next;
        }

        $_->{$element_attriblute} = $remove_redundant_spaces->($_->{$element_attriblute}) for @values;

        # validate main attribute
        my @attr_values = map { $_->{$element_attriblute} } @values;
        push(@invalid_strings, $field)
            unless scalar(@attr_values) && all { $_ } @attr_values;

        next if $field eq 'phone_numbers';

        push(@invalid_strings, $field)
            unless scalar(@attr_values) && all { $_ =~ m/\p{L}/ } @attr_values;
    }

    die $error_sub->('InvalidStringValue', [uniq @invalid_strings]) if @invalid_strings;
    die $error_sub->('InvalidArrayValue',  [uniq @invalid_arrays])  if @invalid_arrays;

# numeric vlues
    my @invalid_numericals;
    for (qw/commission_deposit commission_withdrawal min_withdrawal max_withdrawal/) {
        $args->{$_} //= 0;
        push(@invalid_numericals, $_) unless looks_like_number($args->{$_});
    }
    die $error_sub->('InvalidNumericValue', \@invalid_numericals) if @invalid_numericals;

# commissions
    my @invalid_commissions;
    $args->{'commission_deposit'}    += 0;
    $args->{'commission_withdrawal'} += 0;
    for (qw/commission_deposit commission_withdrawal/) {
        push(@invalid_commissions, $_) unless $args->{$_} >= 0 and $args->{$_} <= MAX_PA_COMMISSION;
    }
    die $error_sub->('ValueOutOfRange', \@invalid_commissions, params => [0, MAX_PA_COMMISSION]) if @invalid_commissions;

    for (qw/commission_deposit commission_withdrawal/) {
        push(@invalid_commissions, $_) unless $args->{$_} =~ m/^\d(.\d{1,2})?$/;
    }
    die $error_sub->('TooManyDecimalPlaces', \@invalid_commissions, params => [2]) if @invalid_commissions;

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
    $args->{affiliate_id} //= '';
    $args->{summary}      //= '';
    $args->{is_listed}    //= 0;
    $args->{status} = undef if (!length $args->{status});

    if ($args->{code_of_conduct_approval}) {
        # If coc time is already set, don't touch it; otherwise set to current time.
        $args->{code_of_conduct_approval_time} = $pa ? Date::Utility->new($pa->code_of_conduct_approval_time)->epoch : time();
    } else {
        #  clear coc time; because it's not approved.
        $args->{code_of_conduct_approval_time} = undef;
    }

    return $args;
}

=head2  sibling_payment_agents

Get the list of all sibling payment agents, including the current payment agent.
Returns an array of PAs.

=cut

sub sibling_payment_agents {
    my $self = shift;

    my @result = map { $_->get_payment_agent // () } $self->client->user->clients;
    @result = sort { $a->client_loginid cmp $b->client_loginid } @result;

    return @result;
}

=head2  copy_details_to

Copy current PA's attributes to one of it's siblings. Withdrawal limits will be converted using exchange rates.

=cut

sub copy_details_to {
    my ($self, $sibling_pa) = @_;

    return 1 if $self->client_loginid eq $sibling_pa->client_loginid;

    my @column_names = BOM::Database::AutoGenerated::Rose::PaymentAgent->meta->column_names;
    # client loginid and currency won't be copied
    @column_names = grep { $_ !~ qr/client_loginid|currency_code/ } @column_names;

    $sibling_pa->$_($self->$_) for @column_names;

    my $withdrawal_limits = $self->convert_withdrawal_limits($sibling_pa->currency_code);
    $sibling_pa->$_($withdrawal_limits->{$_}) for keys %$withdrawal_limits;

    # set linked details
    $sibling_pa->$_($self->$_) for (qw/urls phone_numbers supported_payment_methods/);

    $sibling_pa->save;

    return $sibling_pa->set_countries($self->get_countries());
}

=head2  convert_withdrawal_limits

Converts withdrawal limits of the current PA to a different currency.
It accepts the folllowing required argument:

=over 4

=item C<currency> - the target currency

=back

Returns new values as a hash-ref.

=cut

sub convert_withdrawal_limits {
    my ($self, $currency) = @_;

    my $result;
    for my $limit (qw/max_withdrawal min_withdrawal/) {
        $result->{$limit} = convert_currency($self->{$limit}, $self->currency_code, $currency);
        $result->{$limit} = financialrounding('amount', $currency, $result->{$limit});
    }

    return $result;
}

=head2  service_is_allowed

Takes a service name and tells if the service is allowed for the current payment agent.
Certain services are blocked for the authenticated payment agents,
some of which can be allowed from backoffice. 
It takes the following args:

=over 4

=item C<service> - the service name.

=back

=cut

sub service_is_allowed {
    my ($self, $service) = @_;

    # no service is restricted for unauthorized payment agents
    return 1 unless ($self->status // '') eq 'authorized';

    # unrestricted services are alway allowed
    return 1 if none { $_ eq $service } RESTRICTED_SERVICES->@*;

    return 1 if $self->tier_details->{$service};
}

=head2 cashier_withdrawable_balance

Gets balance available to withdraw via an external cashier.
Returns a hashref with the following keys:

=over 4

=item C<available> - amount available to withdraw.

=item C<commission> - commission received.

=item C<previous withdrawals> - amount already withdrawn via external cashier.

=back

=cut

sub cashier_withdrawable_balance {
    my ($self) = @_;

    my %payment_types = (
        mt5_transfer     => 'commission',
        affiliate_reward => 'commission',
        arbitrary_markup => 'commission',
        external_cashier => 'payout',
        crypto_cashier   => 'payout',
    );

    my ($commission, $payout);

    for my $sibling ($self->sibling_payment_agents) {
        next if ($sibling->status // '') ne 'authorized';

        my @payment_totals = $sibling->client('replica')->payment_type_totals(payment_types => [keys %payment_types])->@*;
        my $pa_commission =
            sum map { $_->{deposits} - $_->{withdrawals} } grep { $payment_types{$_->{payment_type}} eq 'commission' } @payment_totals;
        my $pa_payout = sum map { $_->{withdrawals} } grep { $payment_types{$_->{payment_type}} eq 'payout' } @payment_totals;
        $commission += convert_currency($pa_commission, $sibling->client->currency, $self->client->currency) if $pa_commission;
        $payout     += convert_currency($pa_payout,     $sibling->client->currency, $self->client->currency) if $pa_payout;
    }

    my $limit = $self->service_is_allowed('cashier_withdraw') ? $self->client->account->balance : max(0, ($commission // 0) - ($payout // 0));

    return {
        available  => $limit,
        commission => $commission // 0,
        payouts    => $payout     // 0,
    };
}

1;
