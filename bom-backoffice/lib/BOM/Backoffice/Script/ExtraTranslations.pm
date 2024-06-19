package BOM::Backoffice::Script::ExtraTranslations;

use Moose;
with 'App::Base::Script';

use IO::File;
use File::ShareDir;
use Module::Load::Conditional qw( can_load );
use Locale::Maketext::Extract;
use YAML::XS qw(LoadFile);
use LandingCompany::Registry;

use Finance::Contract::Category;
use Finance::Underlying::Market::Registry;
use Finance::Underlying::SubMarket::Registry;

use BOM::MarketData qw(create_underlying create_underlying_db);
use BOM::MarketData::Types;
use BOM::Product::Static;
use BOM::User::Static;
use BOM::OAuth::Static;
use Finance::Contract::Longcode;
use Business::Config;
use BOM::Config::Runtime;
use BOM::Config;
use BOM::Config::CurrencyConfig;
use BOM::Backoffice::Request qw(request);
use Brands;
use BOM::Backoffice::Script::CustomerIOTranslation;

has file_container => (
    is         => 'ro',
    isa        => 'ArrayRef[Str]',
    lazy_build => 1,
);

sub _build_file_container {
    my $self        = shift;
    my $current_pot = IO::File->new($self->pot_filename, '<:utf8');
    my @content     = <$current_pot>;
    return [map { chomp; $_ } @content];
}

has pot_filename => (
    is      => 'rw',
    isa     => 'Str',
    default => '',
);

has pot_append_fh => (
    is         => 'ro',
    isa        => 'IO::File',
    lazy_build => 1,
);

sub _build_pot_append_fh {
    my $self = shift;
    return IO::File->new($self->pot_filename, '>>:utf8');
}

sub documentation {
    return "Populates our pot file with translations that are not directly picked up by xgettext.pl. Run it with the location to pot file.";
}

sub cli_template {
    return "$0 [options] messages.po";
}

sub script_run {
    my ($self, $pot_filename) = @_;

    die "Unable to open $pot_filename for writing" if (not -w $pot_filename);

    $self->pot_filename($pot_filename);
    my $fh = $self->pot_append_fh;

    print $fh "\n# Start of extra_translations\n";
    $self->add_underlyings;
    $self->add_contract_categories;
    $self->add_contract_types;
    $self->add_longcodes;
    $self->add_messages;
    $self->add_p2p_payment_methods;
    $self->add_idv_document_types;
    $self->add_onfido_document_types;
    $self->add_customerio_emails;

    return 0;
}

sub add_underlyings {
    my $self = shift;

    my @underlyings = map { create_underlying($_) } create_underlying_db()->get_symbols_for(
        market           => [Finance::Underlying::Market::Registry->all_market_names],
        exclude_disabled => 1
    );

    my $fh = $self->pot_append_fh;

    foreach my $underlying (sort { $a->{display_name} cmp $b->{display_name} } grep { $_->{display_name} } @underlyings) {
        my $msgid = $self->msg_id($underlying->{display_name});
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    $self->add_markets;
    $self->add_submarkets;

    return 0;
}

sub add_contract_types {
    my $self = shift;

    my $fh = $self->pot_append_fh;

    my $contract_type_config = Finance::Contract::Category::get_all_contract_types();

    foreach my $contract_type (sort keys %{$contract_type_config}) {
        next if ($contract_type eq 'INVALID');

        if (my $display_name = $contract_type_config->{$contract_type}->{display_name}) {
            my $msgid = $self->msg_id($display_name);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }

    return;
}

sub add_contract_categories {
    my $self = shift;

    my $fh = $self->pot_append_fh;
    my @all_categories =
        map { Finance::Contract::Category->new($_) }
        LandingCompany::Registry->get_default_company->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config)
        ->values_for_key('contract_category');

    foreach my $contract_category (sort { $a->display_name cmp $b->display_name } grep { $_->display_name } @all_categories) {
        my $msgid = $self->msg_id($contract_category->display_name);
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }
    foreach my $contract_category (sort { $a->explanation cmp $b->explanation } grep { $_->explanation } @all_categories) {
        my $msgid = $self->msg_id($contract_category->explanation);
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    return;
}

sub add_markets {
    my $self = shift;

    my $fh = $self->pot_append_fh;

    my @markets = Finance::Underlying::Market::Registry->all();

    foreach my $market (sort { $a->display_name cmp $b->display_name } grep { $_->display_name } @markets) {
        my $msgid = $self->msg_id($market->display_name);
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }
    foreach my $market (sort { $a->explanation cmp $b->explanation } grep { $_->explanation } @markets) {
        my $msgid = $self->msg_id($market->explanation);
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }
    return;
}

sub add_submarkets {
    my $self = shift;

    my $fh = $self->pot_append_fh;

    my @sub_markets = Finance::Underlying::SubMarket::Registry->all();

    foreach my $submarket (sort { $a->display_name cmp $b->display_name } grep { $_->display_name } @sub_markets) {
        my $msgid = $self->msg_id($submarket->display_name);
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }
    foreach my $submarket (sort { $a->explanation cmp $b->explanation } grep { $_->explanation } @sub_markets) {
        my $msgid = $self->msg_id($submarket->explanation);
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    foreach
        my $subgroup (sort { $a->{subgroup}->{display_name} cmp $b->{subgroup}->{display_name} } grep { $_->{subgroup}->{display_name} } @sub_markets)
    {
        my $msgid = $self->msg_id($subgroup->{subgroup}->{display_name});
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    return;
}

sub add_longcodes {
    my $self = shift;

    my $fh        = $self->pot_append_fh;
    my $longcodes = Finance::Contract::Longcode::get_longcodes();

    foreach my $longcode (sort keys %$longcodes) {
        my $msgid = $self->msg_id($longcodes->{$longcode});
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    return;
}

sub add_messages {
    my $self = shift;

    my $fh               = $self->pot_append_fh;
    my @message_mappings = (
        BOM::Product::Static::get_error_mapping(), BOM::Product::Static::get_generic_mapping(),
        BOM::User::Static::get_error_mapping(),    BOM::OAuth::Static::get_message_mapping(),
        BOM::Config::CurrencyConfig::local_currencies(),
    );

    foreach my $message_mapping (@message_mappings) {
        foreach my $message (sort keys %$message_mapping) {
            my $msgid = $self->msg_id($message_mapping->{$message});
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }
    return;
}

=head2 add_p2p_payment_methods

Adds localizable strings from bom-config/share/p2p_payment_methods.yml

=cut

sub add_p2p_payment_methods {
    my $self = shift;

    my $fh     = $self->pot_append_fh;
    my $config = BOM::Config::p2p_payment_methods();

    my $methods = {
        map {
            $_->{display_name} => [map { $_->{display_name} } values $_->{fields}->%*]
        } values %$config
    };

    foreach my $method (sort keys %$methods) {
        my $msgid = $self->msg_id($method);
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh "msgctxt \"payment method name\"\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
        for my $field (sort $methods->{$method}->@*) {
            my $msgid = $self->msg_id($field);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "msgctxt \"field for payment method $method\"\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }

    return;
}

=head2 add_idv_document_types

Adds localizable strings from bom-config/share/idv_config.yml

=cut

sub add_idv_document_types {
    my $self   = shift;
    my $fh     = $self->pot_append_fh;
    my $config = request()->brand->countries_instance->countries_list;

    for my $country_config (values $config->%*) {
        for (values $country_config->{config}->{idv}->{document_types}->%*) {
            my $msgid = $self->msg_id($_->{display_name});
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "msgctxt \"IDV document type \"\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }

    return;
}

=head2 add_onfido_document_types

Adds localizable strings from bom-config/share/onfido_supported_documents.yml

=cut

sub add_onfido_document_types {
    my $self   = shift;
    my $fh     = $self->pot_append_fh;
    my $config = Business::Config->new->onfido_supported_documents();

    for my $country_config ($config->@*) {
        for ($country_config->{doc_types_list}->@*) {
            my $msgid = $self->msg_id($_);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "msgctxt \"Onfido document type \"\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }
    return;
}

=head2 add_customerio_emails

Adds localizable srings from Customer IO emails.
Will only run if CUSTOMERIO_TOKEN is present in environment.

=cut

sub add_customerio_emails {
    my $self = shift;

    my $tokens = $ENV{CUSTOMERIO_TOKENS_I18N} or return;
    my $fh     = $self->pot_append_fh;

    for my $token (split(/\s*?,\s*?/, $tokens)) {

        my $cio       = BOM::Backoffice::Script::CustomerIOTranslation->new(token => $token);
        my $campaigns = $cio->get_campaigns;

        for my $campaign (@$campaigns) {
            next unless $campaign->{updateable};
            my $type = $campaign->{template}{type};
            my $name = $campaign->{name};

            my $result = $cio->process_camapign($campaign);
            for my $string ($result->{strings}->@*) {
                my $msgid = $self->msg_id($string->{loc_text});
                if ($self->is_id_unique($msgid)) {
                    print $fh "\n";
                    print $fh "msgctxt \"Customer.io $type: $name \"\n";
                    print $fh $msgid . "\n";
                    print $fh "msgstr \"\"\n";
                }
            }
        }
    }
}

sub is_id_unique {
    my ($self, $key) = @_;

    my $flag = 0;
    if (not exists $self->_extant_msg_ids->{$key}) {
        $flag = 1;
        $self->_extant_msg_ids->{$key} = undef;
    }

    return $flag;
}

sub msg_id {
    my $self   = shift;
    my $string = shift;
    return 'msgid "' . Locale::Maketext::Extract::_maketext_to_gettext($string) . '"';
}

has _extant_msg_ids => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build__extant_msg_ids {
    my $self = shift;

    return {map { $_ => undef } grep { /^msgid / } (@{$self->file_container})};
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
