package BOM::User::Client;
# ABSTRACT: binary.com client handling and business logic

use strict;
use warnings;

our $VERSION = '0.145';

use parent 'BOM::Database::AutoGenerated::Rose::Client';

use Email::Address::UseXS;
use Email::Stuffer;
use Date::Utility;
use List::Util qw/all/;
use Locale::Country::Extra;
use Format::Util::Numbers qw(roundcommon);
use BOM::Platform::Context qw (request);

use Rose::DB::Object::Util qw(:all);
use Rose::Object::MakeMethods::Generic scalar => ['self_exclusion_cache'];

use LandingCompany::Registry;

use ExchangeRates::CurrencyConverter qw(convert_currency);

use BOM::Platform::Account::Real::default;

use BOM::Database::ClientDB;
use BOM::User::Client::Payments;
use BOM::User::Client::PaymentAgent;
use BOM::User::Client::Status;
use BOM::User::Client::Account;
use BOM::User::FinancialAssessment qw(is_section_complete decode_fa);
use BOM::User::Utility;
use BOM::Platform::Event::Emitter;
use BOM::Database::DataMapper::Account;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::AutoGenerated::Rose::Client::Manager;
use BOM::Database::AutoGenerated::Rose::SelfExclusion;
use BOM::Config;

# this email address should not be added into brand as it is specific to internal system
my $SUBJECT_RE = qr/(New Sign-Up|Update Address)/;

my $META = __PACKAGE__->meta;    # rose::db::object::manager meta rules. Knows our db structure

sub rnew { return shift->SUPER::new(@_) }

sub new {
    my $class = shift;
    my $args = shift || die 'BOM::User::Client->new called without args';

    my $loginid = $args->{loginid};
    die "no loginid" unless $loginid;

    my $operation = delete $args->{db_operation};

    my $self = $class->SUPER::new(%$args);

    $self->set_db($operation) if $operation;

    $self->load(speculative => 1) || return undef;    # must exist in db

    return $self;
}

sub get_instance {
    my $args = shift;
    return __PACKAGE__->new($args);
}

#              real db column                                    =>  legacy name
$META->column('address_city')->method_name('get_set' => 'city');
$META->column('address_line_1')->method_name('get_set' => 'address_1');
$META->column('address_line_2')->method_name('get_set' => 'address_2');
$META->column('address_postcode')->method_name('get_set' => 'postcode');
$META->column('address_state')->method_name('get_set' => 'state');
$META->column('client_password')->method_name('get_set' => 'password');

my $date_inflator_ymdhms = sub {
    my $self = shift;
    my $val = shift // return undef;
    return $val unless ref($val);
    return $val->isa('DateTime') ? ($val->ymd . ' ' . $val->hms) : $val;
};

my $date_inflator_ymd = sub {
    my $self = shift;
    my $val = shift // return undef;
    return $val unless ref($val);
    return $val->isa('DateTime') ? $val->ymd : $val;
};

$META->column('date_of_birth')->add_trigger(inflate => $date_inflator_ymd);
$META->column('date_of_birth')->add_trigger(deflate => $date_inflator_ymd);
$META->column('date_joined')->add_trigger(inflate => $date_inflator_ymdhms);
$META->column('date_joined')->add_trigger(deflate => $date_inflator_ymdhms);

my %DEFAULT_VALUES = (
    cashier_setting_password => '',
    latest_environment       => '',
    restricted_ip_address    => '',
);

$META->column($_)->default($DEFAULT_VALUES{$_}) for sort keys %DEFAULT_VALUES;

# END OF METADATA -- do this after all 'meta' calls.
$META->initialize(replace_existing => 1);

sub save {
    my $self = shift;
    # old code can set these numeric columns to ''.  should have been undef.
    for my $col (qw/custom_max_acbal custom_max_daily_turnover custom_max_payout/) {
        my $val = $self->$col // next;
        $self->$col(undef) if $val eq '';    # if we get here, it's defined.
    }

    $self->set_db('write');
    my $r = $self->SUPER::save(cascade => 1);    # Rose
    return $r;
}

sub store_details {
    my ($self, $args) = @_;

    $self->aml_risk_classification('low') unless $self->is_virtual;

    $self->$_($args->{$_}) for sort keys %$args;

    # special cases.. force empty string if necessary in these not-nullable cols.  They oughta be nullable in the db!
    for (qw(citizen address_2 state postcode salutation)) {
        $self->$_ || $self->$_('');
    }

    # resolve Gender from Salutation
    if ($self->salutation and not $self->gender) {
        my $gender = (uc $self->salutation eq 'MR') ? 'm' : 'f';
        $self->gender($gender);
    }

    $self->gender('m') unless $self->gender;

    return undef;
}

sub register_and_return_new_client {
    my $class = shift;
    my $args  = shift;

    my $broker = $args->{broker_code} || die "can't register a new client without a broker_code";
    my $self = $class->rnew(broker => $broker);

    store_details($self, $args);

    $self->set_db('write');

    my $sql    = "SELECT nextval('sequences.loginid_sequence_$broker')";
    my $dbic   = $self->db->dbic;
    my @seqnum = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute();
            return $sth->fetchrow_array();
        });

    $self->loginid("$broker$seqnum[0]");
    return $self->save;
}

sub full_name {
    my $self = shift;
    return $self->salutation . ' ' . $self->first_name . ' ' . $self->last_name;
}

sub landing_company {
    my $self = shift;
    return LandingCompany::Registry->get_by_broker($self->broker);
}

sub set_promotion {
    my $self = shift;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
        $self->client_promo_code(undef);    # empty Rose's read-only version..
    }
    # get the existing one or make a dummy one..
    if (my $obj = $self->client_promo_code) {
        return $obj;
    }
    my %args = (
        broker         => $self->broker,
        client_loginid => $self->loginid,
        status         => 'NOT_CLAIM',
        mobile         => '',
        apply_date     => Date::Utility->new->db_timestamp,
        db             => $self->db,
    );
    my $obj = BOM::Database::AutoGenerated::Rose::ClientPromoCode->new(%args);
    return $self->client_promo_code($obj);
}

# support legacy calls to these get/set shortcuts from Client to the promo_code record
sub promo_code {
    my $self = shift;
    return $self->set_promotion->promotion_code(@_) if @_;
    return ($self->client_promo_code || return)->promotion_code;
}

sub promo_code_status {
    my $self = shift;
    return $self->set_promotion->status(@_) if @_;
    return ($self->client_promo_code || return)->status;
}

sub promo_code_apply_date {
    my $self = shift;
    return $self->set_promotion->apply_date(@_) if @_;
    return ($self->client_promo_code || return)->apply_date;
}

sub promo_code_checked_in_myaffiliates {
    my $self = shift;
    return $self->set_promotion->checked_in_myaffiliates(@_) if @_;
    return ($self->client_promo_code || return)->checked_in_myaffiliates;
}

sub by_promo_code {
    my ($class, %args) = @_;
    my $broker = $args{broker_code} || die 'by_promo_code needs a broker_code';
    my $db = $class->rnew(broker => $broker)->db;
    my $clients = BOM::Database::AutoGenerated::Rose::Client::Manager->get_client(
        db           => $db,
        with_objects => ['client_promo_code'],
        query        => [%args],
        sort_by      => 't1.broker_code, t1.loginid'
    );
    # turn BPDPR::Client objects into (much smarter) Client objects
    return map { bless $_, $class } @$clients;
}

sub by_args {
    my ($class, %query) = @_;
    my $broker = $query{broker_code} || die 'by_args needs a broker_code';
    my %opts = (
        db      => $class->rnew(broker => $broker)->db,
        sort_by => 'broker_code, loginid'
    );
    if (my $limit = delete $query{limit}) {
        $opts{limit} = $limit;
    }
    my $clients = BOM::Database::AutoGenerated::Rose::Client::Manager->get_client(%opts, query => [%query]);
    # turn BPDPR::Client objects into (much smarter) Client objects
    return [map { bless $_, $class } @$clients];
}

sub get_objects_from_sql {
    my ($class, %args) = @_;
    my $broker = delete $args{broker_code} || die 'get_objects_from_sql needs a broker_code';
    $args{db} ||= $class->rnew(broker => $broker)->db;
    my $clients = BOM::Database::AutoGenerated::Rose::Client::Manager->get_objects_from_sql(%args);
    # turn BPDPR::Client objects into (much smarter) Client objects
    return [map { bless $_, $class } @$clients];
}

sub is_virtual { return shift->broker =~ /^VR/ }

sub has_funded { return shift->first_funded_date ? 1 : 0 }

sub get_authentication {
    my $self            = shift;
    my $method          = shift;
    my $column          = shift;
    my $authentications = {map { $_->authentication_method_code => $_ } $self->client_authentication_method};
    my $obj             = $authentications->{$method} || return undef;
    return $column ? $obj->$column : $obj;
}

sub set_authentication {
    my $self   = shift;
    my $method = shift;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
        $self->client_authentication_method(undef);    # throw out my read-only versions..
    }
    return $self->get_authentication($method) || do {
        $self->add_client_authentication_method({
            authentication_method_code => $method,
            status                     => 'pending'
        });
        $self->get_authentication($method);
        }
}

=head2 risk_level

Get the risk level of clients, based on:

- SR (Social Responsibility): Always high for clients that have breached thresholds
and have no financial assessment

- AML (Anti-Money Laundering): Applies for clients under all landing companies

=cut

sub risk_level {
    my $client = shift;

    my $risk = $client->aml_risk_classification // '';

    # use `low`, `standard`, `high` as prepending `manual override` string is for internal purpose
    $risk =~ s/manual override - //;

    if ($client->landing_company->social_responsibility_check_required && !$client->financial_assessment) {
        $risk = 'high'
            if BOM::Config::RedisReplicated::redis_events()->get($client->loginid . '_sr_risk_status');
    }

    return $risk;
}

=head2 is_financial_assessment_complete

Check if the client has filled out the financial assessment information:

- For non-MF, only the the financial information (FI) is required and risk level is high.
- For MF, both the FI and trading experience is required, regardless of rish level.
    
=cut

sub is_financial_assessment_complete {
    my $self = shift;

    my $sc                   = $self->landing_company->short;
    my $financial_assessment = decode_fa($self->financial_assessment());

    my $is_FI = is_section_complete($financial_assessment, 'financial_information');

    if ($sc ne 'maltainvest') {
        return 0 if ($self->risk_level() eq 'high' and not $is_FI);
        return 1;
    }

    my $is_TE = is_section_complete($financial_assessment, 'trading_experience');

    return 0 unless ($is_FI and $is_TE);

    return 1;
}

=head2 documents_expired

documents_expired returns a boolean indicating if this client (or any related clients)
have any POI documents (passport, proofid, driverslicense, vf_id, vf_face_id) which
have expired, or the expiration is before a specific date.

Takes one argument:

=over 4

=item * $date_limit

If this argument is not specified, the sub which check for documents which have expired
(i.e. have an expiration date yesterday or earlier).
If this argument is specified, the sub will check for documents whose expiration
date is earlier than the specified date.

=cut

sub documents_expired {
    my ($self, $date_limit) = @_;
    $date_limit //= Date::Utility->new();

    return 0 if $self->is_virtual;

    my @query_params = ($self->loginid, $date_limit->db_timestamp);
    my $dbic_code = sub {
        my $query = $_->prepare('SELECT * FROM betonmarkets.get_expired_documents_loginids($1::TEXT, $2::DATE)');
        $query->execute(@query_params);
        return $query->fetchrow_arrayref();
    };

    return 0 + !!($self->db->dbic->run(fixup => $dbic_code));
}

sub has_valid_documents {
    my $self  = shift;
    my $today = Date::Utility->today;
    for my $doc ($self->client_authentication_document) {
        my $expires = $doc->expiration_date || next;
        next if defined $doc->status and $doc->status eq 'uploading';
        return 1 if Date::Utility->new($expires)->is_after($today);
    }
    return undef;
}

sub fully_authenticated {
    my $self = shift;

    for my $method (qw/ID_DOCUMENT ID_NOTARIZED/) {
        my $auth = $self->get_authentication($method);
        return 1 if $auth and $auth->status eq 'pass';
    }

    return 0;
}

sub authentication_status {
    my ($self) = @_;

    my $notarized = $self->get_authentication('ID_NOTARIZED');

    return 'notarized' if $notarized and $notarized->status eq 'pass';

    my $id_auth = $self->get_authentication('ID_DOCUMENT');

    return 'no' unless $id_auth;

    my $id_auth_status = $id_auth->status;

    return 'scans' if $id_auth_status eq 'pass';

    return $id_auth_status;
}

sub set_exclusion {
    my $self = shift;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
    }
    # return the existing one..
    if (my $obj = $self->self_exclusion) {
        $obj->db($self->db);
        $self->self_exclusion_cache([$obj]);
        return $obj;
    }
    # or make a new one
    $self->self_exclusion(my $obj = BOM::Database::AutoGenerated::Rose::SelfExclusion->new());
    $self->self_exclusion_cache([$obj]);
    return $self->self_exclusion;
}

# make this relationship return its smarter version too
sub get_payment_agent {
    my $self = shift;
    my $obj  = $self->payment_agent || return undef;
    my $pa   = bless $obj, 'BOM::User::Client::PaymentAgent';
    return $pa;
}

# return a (new or existing) writeable BOM::User::Client::PaymentAgent
sub set_payment_agent {
    my $self = shift;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
    }
    # return the existing one..
    if (my $obj = $self->get_payment_agent) {
        $obj->db($self->db);
        return $obj;
    }
    my %args = (
        client_loginid => $self->loginid,
        db             => $self->db
    );
    $self->payment_agent(BOM::Database::AutoGenerated::Rose::PaymentAgent->new(%args));
    return $self->get_payment_agent;
}

sub get_self_exclusion {
    my $self = shift;

    my $excl = $self->self_exclusion_cache;
    return $excl->[0] if $excl;

    $excl = $self->self_exclusion;
    $self->self_exclusion_cache([$excl]);
    return $excl;
}

sub get_limits_for_max_deposit {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    return undef unless $excl;

    my $max_deposit = $excl->max_deposit;
    my $begin_date  = $excl->max_deposit_begin_date;
    my $end_date    = $excl->max_deposit_end_date;
    my $today       = Date::Utility->new;

    undef $end_date if $end_date and Date::Utility->new($end_date)->is_before($today);
    undef $begin_date  unless $end_date;
    undef $max_deposit unless $end_date;

    # No limits if any of the fields are missing
    return undef unless $max_deposit and $begin_date and $end_date;

    return +{
        max_deposit => $max_deposit,
        begin       => $begin_date->date,
        end         => $end_date->date
    };
}

sub get_limit_for_account_balance {
    my $self = shift;

    my @maxbalances = ();
    my $max_bal     = BOM::Config::client_limits()->{max_balance};
    my $curr        = $self->currency;
    push @maxbalances, $self->is_virtual ? $max_bal->{virtual}->{$curr} : $max_bal->{real}->{$curr};

    if ($self->get_self_exclusion and $self->get_self_exclusion->max_balance) {
        push @maxbalances, $self->get_self_exclusion->max_balance;
    }

    return List::Util::min(@maxbalances);
}

sub get_limit_for_daily_turnover {
    my $self = shift;

    # turnover maxed at 500K of any currency.
    my @limits = (BOM::Config::client_limits()->{maximum_daily_turnover}{$self->currency});
    if ($self->get_self_exclusion && $self->get_self_exclusion->max_turnover) {
        push @limits, $self->get_self_exclusion->max_turnover;
    }

    return List::Util::min(@limits);
}

sub get_limit_for_daily_losses {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_losses) {
        return $excl->max_losses;
    }
    return undef;
}

sub get_limit_for_7day_turnover {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_7day_turnover) {
        return $excl->max_7day_turnover;
    }
    return undef;
}

sub get_limit_for_7day_losses {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_7day_losses) {
        return $excl->max_7day_losses;
    }
    return undef;
}

sub get_limit_for_30day_turnover {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_30day_turnover) {
        return $excl->max_30day_turnover;
    }
    return undef;
}

sub get_limit_for_30day_losses {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_30day_losses) {
        return $excl->max_30day_losses;
    }
    return undef;
}

sub get_limit_for_open_positions {
    my $self = shift;

    my @limits = BOM::Config::client_limits()->{max_open_bets_default};

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_open_bets) {
        push @limits, $excl->max_open_bets;
    }

    return List::Util::min(@limits);
}

# return undef or an exclusion date string
sub get_self_exclusion_until_date {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    return undef unless $excl;

    my $exclude_until = $excl->exclude_until;
    my $timeout_until = $excl->timeout_until;
    my $today         = Date::Utility->new;
    # Don't uplift exclude_until date for clients under Binary (Europe) Ltd,
    # Binary (IOM) Ltd, and Binary Investments (Europe) Ltd upon expiry.
    # This is in compliance with Section 3.5.4 (5e) of the United Kingdom Gambling
    # Commission licence conditions and codes of practice
    # United Kingdom Gambling Commission licence conditions and codes of practice is
    # applicable to clients under Binary (Europe) Ltd & Binary (IOM) Ltd only. Change is also
    # applicable to clients under Binary Investments (Europe) Ltd for standardisation.
    # (http://www.gamblingcommission.gov.uk/PDF/LCCP/Licence-conditions-and-codes-of-practice.pdf)
    if ($self->landing_company->short !~ /^(?:iom|malta|maltainvest)$/) {
        # undef if expired
        undef $exclude_until
            if $exclude_until and Date::Utility->new($exclude_until)->is_before($today);
    }

    undef $timeout_until if $timeout_until and Date::Utility->new($timeout_until)->is_before($today);

    return undef unless $exclude_until || $timeout_until;

    if ($exclude_until && $timeout_until) {
        my $exclude_until_dt = Date::Utility->new($exclude_until);
        my $timeout_until_dt = Date::Utility->new($timeout_until);

        return $exclude_until_dt->date if $exclude_until_dt->epoch < $timeout_until_dt->epoch;
        return $timeout_until_dt->datetime_yyyymmdd_hhmmss_TZ;
    }

    return Date::Utility->new($exclude_until)->date if $exclude_until;
    return Date::Utility->new($timeout_until)->datetime_yyyymmdd_hhmmss_TZ;
}

sub get_limit_for_payout {
    my $self = shift;

    my $max_payout = BOM::Config::client_limits()->{max_payout_open_positions};

    return $max_payout->{$self->currency};
}

=head2 get_today_transfer_summary

Returns today (GMT timezone ) money transfers summary for the user based on the given type
default payment type is: 'internal_transfer'

=cut

sub get_today_transfer_summary {
    my ($self, $transfer_type) = @_;
    $transfer_type //= 'internal_transfer';
    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT * from payment.get_today_account_transfer_summary(?, ?);", undef, $self->account->id, $transfer_type);
        });
}

sub get_limit {
    my $self = shift;
    my $args = shift || die 'get_limit needs args';
    my $for  = $args->{for} || die 'get_limit needs a "for" arg';

    $for = 'get_limit_for_' . $for;
    return $self->$for;
}

sub currency {
    my $self = shift;

    return 'USD' if $self->is_virtual;

    if (my $account = $self->default_account) {
        return $account->currency_code();
    }

    return 'GBP' if $self->residence eq 'gb';
    return 'AUD' if $self->landing_company->short eq 'svg' and $self->residence eq 'au';
    return $self->landing_company->legal_default_currency;
}

sub has_deposits {
    my $self = shift;
    my $args = shift;

    return $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT * from betonmarkets.has_first_deposit(?, ?);", undef, $self->loginid, $args->{exclude});
        })->{has_first_deposit};
}

sub is_first_deposit_pending {
    my $self = shift;
    # we need to ignore free gift as its payment done manually by marketing
    return !$self->is_virtual && !$self->has_deposits({exclude => ['free_gift']});
}

sub first_funded_currency { return shift->_ffd->{first_funded_currency} }
sub first_funded_amount   { return shift->_ffd->{first_funded_amount} }
sub first_funded_date     { return shift->_ffd->{first_funded_date} }

sub _ffd {    # first_funded_details
    my $self           = shift;
    my $ffd            = {};
    my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $self->loginid});
    if (my $ff = $payment_mapper->first_funding) {
        $ffd->{first_funded_date}     = Date::Utility->new($ff->payment_time->epoch);
        $ffd->{first_funded_amount}   = sprintf '%.2f', $ff->amount;
        $ffd->{first_funded_currency} = $ff->account->currency_code();
    }
    return $ffd;
}

# The following 2 subroutines are proxies to
# the real account sub routine and can be removed
# when the calls are refactored.

sub set_default_account {
    my $self     = shift;
    my $currency = shift;
    return $self->account($currency);
}

sub default_account {
    my $self = shift;
    return $self->account();
}

=head2 account


C<< $account = $client->account($currency) >>

If one does not exist it creates an account entry assigns it a currency symbol
and marks it as default.  If there is already a default currency set it makes
no changes.

Takes the following parameters.

=over 4

=item * C<currency> - (optional) A string representing 3 character currency as defined in L<ISO 4217|https://en.wikipedia.org/wiki/ISO_4217>. An account will be created based on the given string, if it does not exist.
=back

Returns

=over 4

=item * C<Account> - An Account Object of type BOM::User::Client::Account

=back

=cut

sub account {
    my $self     = shift;
    my $currency = shift;

    my $account = BOM::User::Client::Account->new(
        client_loginid => $self->loginid,
        currency_code  => $currency,
        db             => $self->db,
    );

    #calls to Account new will always return some sort of object because that's how moo works,
    #so to maintain backward compatibility we return undef if no currency_code exists showing
    #an empty account.
    return undef if !defined $account->currency_code();

    return $account;
}

sub open_bets {
    my $self    = shift;
    my $account = $self->default_account || return undef;
    my $fmbs    = $account->find_financial_market_bet(query => [is_sold => 0]);
    return @$fmbs;
}

=head1 CUSTOMER SERVICE RELATED FUNCTIONS

These are for interfacing with customer service facing applications (like email
queues or CRM applications).

=head2 add_note($subject, $content)

Adds a note for a customer record.  This is supposed to integrate with whatever
CS is doing, and returns 1 on success or 0 on failure.

Currently this is simply an emailer which sends the email to the desk.com
system.  Since we go through localhost, we die if there is an error.  This
might happen if somehow we are sending invalid SMTP commands or the like.

As the implementation changes the exceptions may change as well, but the basic
guarantee is that if there is a serious system error that prevents this from
working going forward with any input, it should die.

=cut

sub add_note {
    my ($self, $subject, $content) = @_;

    # send to different email based on the subject of the email, as desk.com handles different subject and email differently.
    my $email_add = ($subject =~ /$SUBJECT_RE/) ? 'support_new_account' : 'support';
    $email_add = request()->brand->emails($email_add);

    # We want to record who this note is for, but many legacy places already include client ID.
    # If you're reading this, please check for those and remove the condition.
    my $loginid = $self->loginid;
    $subject = $loginid . ': ' . $subject unless $subject =~ /\Q$loginid/;
    return Email::Stuffer->from($email_add)->to($email_add)->subject($subject)->text_body($content)->send_or_die;
}

=pod

=head2 get_promocode_dependent_limit

get the limits based on promocode

=cut

sub get_promocode_dependent_limit {
    my ($client) = @_;

    my $payment_mapper = BOM::Database::DataMapper::Payment->new({
        'client_loginid' => $client->loginid,
        'currency_code'  => $client->currency,
    });

    my $total_free_gift_deposits            = $payment_mapper->get_total_free_gift_deposit();
    my $total_free_gift_rescind_withdrawals = $payment_mapper->get_total_free_gift_rescind_withdrawal();

    my $free_gift_deposits = $total_free_gift_deposits - $total_free_gift_rescind_withdrawals;

    my $frozen_free_gift = 0;
    my $turnover_limit   = 0;

    my $cpc = $client->client_promo_code;
    if ($cpc && $cpc->status !~ /^(CANCEL|REJECT)$/) {

        my $pc = $cpc->promotion;
        $pc->{_json} ||= try { JSON::MaybeXS->new->decode($pc->promo_code_config) } || {};

        if ($pc->promo_code_type eq 'FREE_BET') {

            my $min_turnover = $pc->{_json}{min_turnover};
            my $amount       = $pc->{_json}{amount};

            my $made_actual_deposit = $payment_mapper->get_total_deposit() - $amount;
            if ($made_actual_deposit) {
                $frozen_free_gift = $free_gift_deposits;
            } else {
                my $account_mapper = BOM::Database::DataMapper::Account->new({
                    'client_loginid' => $client->loginid,
                    'currency_code'  => $client->currency,
                });
                $frozen_free_gift = $account_mapper->get_balance();
            }

            $turnover_limit = 25 * $amount;

            # matched bets
            if (defined($min_turnover) and length($min_turnover) > 0) {
                $frozen_free_gift = 0;
            }

            my $txn_data_mapper = BOM::Database::DataMapper::Transaction->new({
                client_loginid => $client->loginid,
                currency_code  => $client->currency,
            });

            if (roundcommon(0.01, $txn_data_mapper->get_turnover_of_account) >= $turnover_limit) {
                $frozen_free_gift = 0;
            }
        }
    }

    return {
        frozen_free_gift         => $frozen_free_gift,
        free_gift_turnover_limit => $turnover_limit,
    };
}

=pod

=head2 get_withdrawal_limits

get withdraw limits

=cut

sub get_withdrawal_limits {
    my $client = shift;

    my $withdrawal_limits = $client->get_promocode_dependent_limit();

    my $max_withdrawal = 0;
    if ($client->default_account) {
        my $balance = $client->default_account->balance;
        $max_withdrawal = List::Util::max(0, $balance - $withdrawal_limits->{'frozen_free_gift'});
    }

    $withdrawal_limits->{'max_withdrawal'} = $max_withdrawal;

    return $withdrawal_limits;
}

=head2 user

    my $user = $client->user;
returns the user associated with the client : C<BOM::User>

=cut

sub user {
    my $self = shift;

    my $id = $self->binary_user_id;
    my $user;

    # Use binary_user_id to get the user
    $user = BOM::User->new(id => $id) if $id;
    # Fall back to loginid if binary_user_id does not work
    $user ||= BOM::User->new(loginid => $self->loginid);
    # Fall back to email if loginid does not work
    # in case that the user object is created but the client has not been registered into it.
    $user ||= BOM::User->new(email => $self->email);

    return $user;
}

=head2 is_available

return false if client is disabled or is duplicated account

=cut

sub is_available {
    my $self = shift;
    foreach my $status (qw(disabled duplicate_account)) {
        return 0 if $self->status->$status();
    }
    return 1;
}

sub real_account_siblings_information {
    my ($self, %args) = @_;
    my $include_disabled = $args{include_disabled} // 1;
    my $include_self     = $args{include_self}     // 1;

    my $user = $self->user;
    # return empty if we are not able to find user, this should not
    # happen but added as additional check
    return {} unless $user;

    my @clients = $user->clients(include_disabled => $include_disabled);

    # filter out virtual clients
    @clients = grep { not $_->is_virtual } @clients;

    my $siblings;
    foreach my $cl (@clients) {
        my $acc = $cl->default_account;

        $siblings->{$cl->loginid} = {
            loginid              => $cl->loginid,
            landing_company_name => $cl->landing_company->short,
            currency => $acc ? $acc->currency_code() : '',
            balance => $acc ? formatnumber('amount', $acc->currency_code(), $acc->balance) : "0.00",
            }
            unless (!$include_self && ($cl->loginid eq $self->loginid));
    }

    return $siblings;
}

sub is_tnc_approval_required {
    my $self = shift;

    return 0 if $self->is_virtual;
    return 0 unless $self->landing_company->tnc_required;

    my $current_tnc_version = BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version;
    my $client_tnc_status   = $self->status->tnc_approval;

    return 1 if (not $client_tnc_status or ($client_tnc_status->{reason} ne $current_tnc_version));

    return 0;
}

sub user_id {
    my $self = shift;
    return $self->binary_user_id // $self->user->{id};
}

sub status {
    my $self = shift;
    if (not $self->{status}) {
        $self->set_db('write') unless $self->get_db eq 'write';
        $self->{status} = BOM::User::Client::Status->new({
            client_loginid => $self->loginid,
            dbic           => $self->db->dbic
        });
    }

    return $self->{status};
}

sub is_pa_and_authenticated {
    my $self = shift;
    return 0 unless my $pa = $self->get_payment_agent();
    return $pa->is_authenticated ? 1 : 0;
}

sub is_same_user_as {
    my ($self, $other_client) = @_;

    return 0 unless $self;

    return 0 unless $other_client;

    return $self->binary_user_id == $other_client->binary_user_id ? 1 : 0;
}

=head2 get_mt5_details

returns hashref contains information we need for MT5 clients

=cut

sub get_mt5_details {
    my $self = shift;
    return {
        name    => $self->first_name . ' ' . $self->last_name,
        email   => $self->email,
        address => $self->address_1,
        phone   => $self->phone,
        state   => $self->state,
        city    => $self->city,
        zipCode => $self->postcode,
        country => Locale::Country::Extra->new()->country_from_code($self->residence),
    };
}

=head2 missing_requirements

Returns a list of missing entries of fields of a given requirement (defaults to signup requirement).

=cut

sub missing_requirements {
    my $self = shift;
    my $requirement = shift // "signup";

    my $requirements = $self->landing_company->requirements->{$requirement};
    my @missing;

    for my $detail (@$requirements) {
        push(@missing, $detail) unless $self->$detail;
    }

    return @missing;
}

=head2 is_region_eu

return 1 or 0 according to client's landing company or the residence for VRT client.

=cut

sub is_region_eu {
    my ($self) = @_;

    if ($self->is_virtual) {

        my $countries_instance = request()->brand->countries_instance;
        my $company            = $countries_instance->real_company_for_country($self->residence);

        return LandingCompany::Registry->new->get($company)->is_eu;
    } else {
        return $self->landing_company->is_eu;
    }

}

=head2 get_open_contracts

Returns the list of open contracts for a given client

=cut

sub get_open_contracts {
    my $client = shift;

    return BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
            operation      => 'replica',
        })->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client->loginid, $client->currency, 'false']);
}

=head2 increment_social_responsibility_values

Pass in an hashref and increment the social responsibility values in redis

=cut

sub increment_social_responsibility_values {
    my ($client, $sr_hashref) = @_;
    my $loginid = $client->loginid;

    my $hash_name  = 'social_responsibility';
    my $event_name = $loginid . '_sr_check';

    my $redis = BOM::Config::RedisReplicated::redis_events_write();

    foreach my $attribute (keys %$sr_hashref) {
        my $field_name = $loginid . '_' . $attribute;
        my $value      = $sr_hashref->{$attribute};

        $redis->hincrbyfloat($hash_name, $field_name, $value);
    }

    # This is only set once; there is no point to queue again and again
    # We only queue if the client is at low-risk only (low-risk means it is not in the hash)
    BOM::Platform::Event::Emitter::emit('social_responsibility_check', {loginid => $loginid})
        if (!$redis->get($loginid . '_sr_risk_status') && $redis->hsetnx($hash_name, $event_name, 1));

    return undef;
}

=head2 increment_qualifying_payments

Pass in a hashref and increment the qualifying payment check values, which 
is either deposit or withdrawals.

If no key is present, a new key is set with an expiry of 30 days (Regulation as at 14th August, 2019)
Otherwise, increment existing key

=cut

sub increment_qualifying_payments {
    my ($client, $args) = @_;
    my $loginid = $client->loginid;

    my $redis     = BOM::Config::RedisReplicated::redis_events();
    my $redis_key = $loginid . '_' . $args->{action} . '_qualifying_payment_check';

    my $payment_check_limits = BOM::Config::payment_limits()->{qualifying_payment_check_limits}->{$client->landing_company->short};

    if ($redis->exists($redis_key)) {
        # abs() is used, as withdrawal transactions have negative amount
        $redis->incrbyfloat($redis_key => abs($args->{amount}));
    } else {
        $redis->set(
            $redis_key => $args->{amount},
            EX         => 86400 * $payment_check_limits->{for_days});
    }

    my $event_name = $loginid . '_qualifying_payment_check';
    BOM::Platform::Event::Emitter::emit('qualifying_payment_check', {loginid => $loginid}) if $redis->setnx($event_name, 1);

    return undef;
}

1;
