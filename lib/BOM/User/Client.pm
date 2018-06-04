package BOM::User::Client;
# ABSTRACT: binary.com client handling and business logic

use strict;
use warnings;

our $VERSION = '0.145';

use feature qw(state);
use Email::Stuffer;
use Date::Utility;
use List::Util qw/any/;
use Format::Util::Numbers qw(roundcommon);
use Try::Tiny;
use JSON::MaybeXS;

use Rose::DB::Object::Util qw(:all);
use Rose::Object::MakeMethods::Generic scalar => ['self_exclusion_cache'];

use LandingCompany::Registry;
use BOM::User::Client::Payments;

use BOM::Platform::Account::Real::default;

use BOM::User::Client::PaymentAgent;
use Postgres::FeedDB::CurrencyConverter qw(amount_from_to_currency);

use parent 'BOM::Database::AutoGenerated::Rose::Client';

use BOM::Database::DataMapper::Account;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::AutoGenerated::Rose::Client::Manager;
use BOM::Database::AutoGenerated::Rose::SelfExclusion;

my $CLIENT_LIMITS_CONFIG = LoadFile('/home/git/regentmarkets/bom-user/config/client_limits.yml');

# value 1 represent it can displayed to client even
# if that status is set, 0 represent not displayed to
# client if that status is set
my $CLIENT_STATUS_TYPES = {
    age_verification  => 1,
    cashier_locked    => 1,
    disabled          => 1,
    unwelcome         => 1,
    withdrawal_locked => 1,
    # UKGC License condition 4.2.1 for UK clients only
    ukgc_funds_protection => 1,
    # MGA License condition 2.7.1.10 for MLT clients only
    tnc_approval => 1,
    # warned client of any potential risks (compliance)
    financial_risk_approval => 1,
    # CRS/FATCA for collecting tax information for maltainvest (compliance)
    crs_tin_information => 1,
    # RTS 12 - Financial Limits - UK Clients
    ukrts_max_turnover_limit_not_set => 1,
    jp_knowledge_test_pending        => 1,
    jp_knowledge_test_fail           => 1,
    jp_activation_pending            => 1,
    # status api call by passing this to get bank details provided
    jp_transaction_detail => 1,
    # we migrated client to single login and kept single login
    # so all other will be marked with this
    migrated_single_email  => 0,
    duplicate_account      => 0,
    professional_requested => 1,
    professional           => 1,
    # TODO (Amin): Find a way to add a config for hidden status codes (prove_*)
    proveid_pending   => 1,
    proveid_requested => 1,
};

sub client_status_types { return $CLIENT_STATUS_TYPES }

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

for (qw/date_of_birth payment_agent_withdrawal_expiration_date/) {
    $META->column($_)->add_trigger(inflate => $date_inflator_ymd);
    $META->column($_)->add_trigger(deflate => $date_inflator_ymd);
}

for (qw/date_joined/) {
    $META->column($_)->add_trigger(inflate => $date_inflator_ymdhms);
    $META->column($_)->add_trigger(deflate => $date_inflator_ymdhms);
}

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
    my $reset_statuses;
    for (values %{$self->{_clr_status}}) {       # see clr_status.
        $_->db($self->db);
        $_->delete;
        $reset_statuses++;
    }
    $self->client_status(undef) if $reset_statuses;
    return $r;
}

sub register_and_return_new_client {
    my $class = shift;
    my $args  = shift;

    my $broker = $args->{broker_code} || die "can't register a new client without a broker_code";
    # assert broker before setting other properties so that correct write-handle will be cascaded!
    my $self = $class->rnew(broker => $broker);

    $self->set_db('write');
    $self->$_($args->{$_}) for sort keys %$args;

    # special cases.. force empty string if necessary in these not-nullable cols.  They oughta be nullable in the db!
    for (qw(citizen address_2 state postcode salutation)) {
        $self->$_ || $self->$_('');
    }

    $self->aml_risk_classification('low') unless $self->is_virtual;

    # resolve Gender from Salutation
    if ($self->salutation and not $self->gender) {
        my $gender = (uc $self->salutation eq 'MR') ? 'm' : 'f';
        $self->gender($gender);
    }
    $self->gender('m') unless $self->gender;

    my $sql    = "SELECT nextval('sequences.loginid_sequence_$broker')";
    my $dbic   = $self->db->dbic;
    my @seqnum = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute();
            return $sth->fetchrow_array();
        });
    $self->loginid("$broker$seqnum[0]");
    $self->save;
    $self->load;

    return $self;
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

sub _change_vip_status {
    my $self = shift;
    my $new_status = (shift) ? 1 : 0;
    if ($new_status != $self->is_vip) {
        my $v = $new_status ? (Date::Utility->new->db_timestamp) : undef;
        $self->vip_since($v);
    }
    return undef;
}

sub is_vip {
    my $self = shift;
    $self->_change_vip_status($_[0]) if @_;    # note $_[0] might be zero or undef
    return $self->vip_since ? 1 : 0;
}

sub is_virtual { return shift->broker =~ /^VR/ }

sub has_funded { return shift->first_funded_date ? 1 : 0 }

sub get_status {
    my ($self, $status_code) = @_;
    die "unknown status_code [$status_code]" unless exists $CLIENT_STATUS_TYPES->{$status_code};
    return List::Util::first {
        $_->status_code eq $status_code and not $self->{_clr_status}->{$status_code};
    }
    $self->client_status;
}

sub set_status {
    my ($self, $status_code, $staff_name, $reason) = @_;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
        $self->client_status(undef);    # throw out my read-only versions..
    }
    delete $self->{_clr_status}->{$status_code};
    my $obj = $self->get_status($status_code) || do {
        $self->add_client_status({status_code => $status_code});
        $self->get_status($status_code);
    };
    $obj->staff_name($staff_name || '');
    $obj->reason($reason         || '');
    $obj->db($self->db);
    return $obj;
}

sub clr_status {
    my ($self, $status_code) = @_;
    my $obj = $self->get_status($status_code) || return undef;
    $self->{_clr_status}->{$status_code} = $obj;
    return $obj;
}

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

sub aml_risk {
    my $self = shift;

    my $risk = $self->aml_risk_classification // '';

    # use `low`, `standard`, `high` as prepending `manual override` string is for internal purpose
    $risk =~ s/manual override - //;

    return $risk;
}

sub is_financial_assessment_complete {
    my $self = shift;

    my $sc  = $self->landing_company->short;
    my $aml = $self->aml_risk();

    my $is_FI = $self->is_financial_information_complete();
    my $is_TE = $self->is_trading_experience_complete();

    return 0 if $sc eq 'maltainvest' and (not $is_FI or not $is_TE);
    return 0 if $sc =~ /^iom|malta|costarica$/ and $aml eq 'high' and $is_FI;
    return 1;
}

sub is_trading_experience_complete {
    my $self = shift;

    my $fa = $self->_decode_financial_assessment();
    my $im = BOM::Platform::Account::Real::default::get_financial_input_mapping();
    my $is_trading_exp_complete =
        all { $fa->{$_} and $fa->{$_}->{answer} } keys %{$im->{trading_experience}};

    return $is_trading_exp_complete;
}

sub is_financial_information_complete {
    my $self = shift;

    my $fa = $self->_decode_financial_assessment();
    my $im = BOM::Platform::Account::Real::default::get_financial_input_mapping();
    my $is_financial_info_complete =
        all { $fa->{$_} and $fa->{$_}->{answer} } keys %{$im->{financial_information}};

    return $is_financial_info_complete;
}

sub _decode_financial_assessment {
    my $self = shift;

    my $fa = $self->financial_assessment();
    $fa = ref($fa) ? JSON::MaybeXS->new->decode($fa->data || '{}') : {};

    return $fa;
}

sub documents_expired {
    my $self  = shift;
    my $today = Date::Utility->today;
    my @docs  = $self->client_authentication_document or return undef;    # Rose
    for my $doc (@docs) {
        my $expires = $doc->expiration_date || next;
        next if defined $doc->status and $doc->status eq 'uploading';
        return 1 if Date::Utility->new($expires)->is_before($today);
    }
    return 0;
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

sub get_limit_for_account_balance {
    my $self = shift;

    my @maxbalances = ();
    my $max_bal     = $CLIENT_LIMITS_CONFIG->{max_balance};
    my $curr        = $self->currency;
    push @maxbalances, $self->is_virtual ? $max_bal->{virtual}->{$curr} : $max_bal->{real}->{$curr};

    if ($self->get_self_exclusion and $self->get_self_exclusion->max_balance) {
        push @maxbalances, $self->get_self_exclusion->max_balance;
    }

    if ($self->custom_max_acbal) {
        push @maxbalances, amount_from_to_currency($self->custom_max_acbal, USD => $curr);
    }

    return List::Util::min(@maxbalances);
}

sub get_limit_for_daily_turnover {
    my $self = shift;

    # turnover maxed at 500K of any currency.
    my @limits = ($CLIENT_LIMITS_CONFIG->{maximum_daily_turnover}{$self->currency});
    if ($self->get_self_exclusion && $self->get_self_exclusion->max_turnover) {
        push @limits, $self->get_self_exclusion->max_turnover;
    }

    if (my $val = $self->custom_max_daily_turnover) {
        push @limits, amount_from_to_currency($val, USD => $self->currency);
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

    my @limits = $CLIENT_LIMITS_CONFIG->{max_open_bets_default};

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

    my $val = $self->custom_max_payout;
    return amount_from_to_currency($val, USD => $self->currency) if defined $val;

    my $max_payout = $CLIENT_LIMITS_CONFIG->{max_payout_open_positions};

    return $max_payout->{$self->currency};
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

    # for Japan, both Virtual & Real a/c use JPY
    return 'JPY' if ($self->residence eq 'jp');
    return 'USD' if $self->is_virtual;

    if (my $account = $self->default_account) {
        return $account->currency_code;
    }

    return 'GBP' if $self->residence eq 'gb';
    return 'AUD' if $self->landing_company->short eq 'costarica' and $self->residence eq 'au';
    return $self->landing_company->legal_default_currency;
}

sub has_deposits {
    my $self           = shift;
    my $args           = shift;
    my $payment_mapper = BOM::Database::DataMapper::Payment->new({'client_loginid' => $self->loginid});
    return $payment_mapper->get_payment_count_exclude_gateway($args);
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
        $ffd->{first_funded_currency} = $ff->account->currency_code;
    }
    return $ffd;
}

sub default_account {
    my $self     = shift;
    my @accounts = $self->account;    # Rose
    return $accounts[0] if @accounts == 1;
    $_->is_default && return $_ for @accounts;
    die "multiple accounts, no default\n" if @accounts;
    return undef;
}

sub set_default_account {
    my $self = shift;
    my $currency = shift || die 'no currency';
    $self->account(undef);            # throw out my read-only versions..
    $self->set_db('write') unless $self->get_db eq 'write';
    if (my $acc = $self->default_account) {
        my $orig_curr = $acc->currency_code;
        die "cannot deal in $currency; clients currency is $orig_curr" if $orig_curr ne $currency;
        return $acc;
    }
    my ($acc) = $self->add_account({
        currency_code => $currency,
        is_default    => 1
    });
    $self->save;
    return $acc;
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
    my $to = 'helpdesk@binary.com';
    $to = 'support-newaccount-notifications@binary.com' if $subject =~ /New Sign-Up/ or $subject =~ /Update Address/;
    my $from = $to;
    return Email::Stuffer->from($from)->to($to)->subject($subject)->text_body($content)->send_or_die;
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
    $user = BOM::User->new({id => $id}) if $id;
    # Fall back to loginid if binary_user_id does not work
    $user ||= BOM::User->new({loginid => $self->loginid});
    # Fall back to email if loginid does not work
    # in case that the user object is created but the client has not been registered into it.
    $user ||= BOM::User->new({email => $self->email});

    return $user;
}

=head2 is_available

return false if client is disabled or is duplicated account

=cut

sub is_available {
    my $self = shift;
    foreach my $status (qw(disabled duplicate_account)) {
        return 0 if $self->get_status($status);
    }
    return 1;
}

sub cookie_string {
    my $self = shift;

    my $str = join(':', $self->loginid, $self->is_virtual ? 'V' : 'R', $self->get_status('disabled') ? 'D' : 'E');

    return $str;
}

sub real_account_siblings_information {
    my ($self, %args) = @_;
    my $include_disabled = $args{include_disabled} // 1;

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
            currency => $acc ? $acc->currency_code : '',
            balance => $acc ? formatnumber('amount', $acc->currency_code, $acc->balance) : "0.00",
        };
    }

    return $siblings;
}

sub is_tnc_approval_required {
    my $self = shift;

    return 0 if $self->is_virtual;
    return 0 unless $self->landing_company->tnc_required;

    my $current_tnc_version = BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version;
    my $client_tnc_status   = $self->get_status('tnc_approval');
    return 1 if (not $client_tnc_status or ($client_tnc_status->reason ne $current_tnc_version));

    return 0;
}

1;
