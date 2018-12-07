#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi);
use f_brokerincludeall;
use HTML::Entities;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Config::Runtime;
use LandingCompany::Registry;

BOM::Backoffice::Sysinit::init();

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation('INTERNAL TRANSFER FEES');

my @all_currencies = LandingCompany::Registry::all_currencies();
my $app_config     = BOM::Config::Runtime->instance->app_config();
my $config         = $app_config->get([
    'payments.transfer_between_accounts.fees.default.fiat_fiat',   'payments.transfer_between_accounts.fees.default.fiat_crypto',
    'payments.transfer_between_accounts.fees.default.fiat_stable', 'payments.transfer_between_accounts.fees.default.crypto_fiat',
    'payments.transfer_between_accounts.fees.default.stable_fiat', 'payments.transfer_between_accounts.fees.by_currency'
]);

my $fee_by_currency = $config->{'payments.transfer_between_accounts.fees.by_currency'};
my $fiat_fiat       = $config->{'payments.transfer_between_accounts.fees.default.fiat_fiat'};
my $fiat_crypto     = $config->{'payments.transfer_between_accounts.fees.default.fiat_crypto'};
my $fiat_stable     = $config->{'payments.transfer_between_accounts.fees.default.fiat_stable'};
my $crypto_fiat     = $config->{'payments.transfer_between_accounts.fees.default.crypto_fiat'};
my $stable_fiat     = $config->{'payments.transfer_between_accounts.fees.default.stable_fiat'};

my (@fiat, @crypto, @stable);
for my $currency (@all_currencies) {
    my $def = LandingCompany::Registry::get_currency_definition($currency);
    push @stable, "'$currency'" if $def->{stable};
    push @fiat,   "'$currency'" if ($def->{type} eq 'fiat');
    push @crypto, "'$currency'" if (($def->{type} eq 'crypto') and (not $def->{stable}));
}

# Get inputs
my $submit = request()->param('_form_submit');

my $action = request()->url_for('backoffice/quant/internal_transfer_fees.cgi');

my $defaults_msg = '';
my $currency_msg = '';
if ($submit) {
    if ($fee_by_currency ne request()->param('fee_by_currency')) {
        $fee_by_currency = request()->param('fee_by_currency');
        $app_config->set({
            'payments.transfer_between_accounts.fees.by_currency' => $fee_by_currency,
        });
        $currency_msg = "<p style='color:green'><strong>SUCCESS: Transfer fees by currency saved.</strong></p>";
    }

    if (   $fiat_fiat != request()->param('fiat_fiat')
        or $fiat_crypto != request()->param('fiat_crypto')
        or $fiat_stable != request()->param('fiat_stable')
        or $crypto_fiat != request()->param('crypto_fiat')
        or $stable_fiat != request()->param('stable_fiat'))
    {
        $fiat_fiat   = request()->param('fiat_fiat');
        $fiat_crypto = request()->param('fiat_crypto');
        $fiat_stable = request()->param('fiat_stable');
        $crypto_fiat = request()->param('crypto_fiat');
        $stable_fiat = request()->param('stable_fiat');

        $app_config->set({
            'payments.transfer_between_accounts.fees.default.fiat_fiat'   => $fiat_fiat,
            'payments.transfer_between_accounts.fees.default.fiat_crypto' => $fiat_crypto,
            'payments.transfer_between_accounts.fees.default.fiat_stable' => $fiat_stable,
            'payments.transfer_between_accounts.fees.default.crypto_fiat' => $crypto_fiat,
            'payments.transfer_between_accounts.fees.default.stable_fiat' => $stable_fiat
        });
        $defaults_msg = "<p style='color:green'><strong>SUCCESS: Default transfer fees saved.</strong></p>";
    }
}

binmode STDOUT, ':encoding(UTF-8)';

Bar("INTERNAL TRANSFER FEES");

print qq~
<script>

// Global variables coming from backend code.
var _fiat_currencies   = [@{[join(',', sort @fiat)]}];
var _crypto_currencies = [@{[join(',', sort @crypto)]}];
var _stable_currencies = [@{[join(',', sort @stable)]}];
var _fiat_fiat = $fiat_fiat;
var _fiat_crypto = $fiat_crypto;
var _fiat_stable = $fiat_stable;
var _crypto_fiat = $crypto_fiat;
var _stable_fiat = $stable_fiat;
var _fee_by_currency = $fee_by_currency;

var _all_currencies = _fiat_currencies.concat(_crypto_currencies).concat(_stable_currencies).sort();

/* 
Validates the input to be a number in range 0-7
*/
function validate_fee(fee, name){
     if (fee.trim().length == 0){
        window.alert(name+" is empty.");
        return false;
    }
    if (isNaN(fee)){
        window.alert(name+" is not a valid number.");
        return false;
    }
    if (fee <= 0 || fee > 7){
        window.alert(name+  " : " + fee + " is not in range 0 (exclusive) - 7 (inclusive).");
        return false;
    }
    if (fee != Math.round(fee * 100) / 100){
        window.alert(name + " exceeds the maximum number of 2 decimals.");
        return false;
    }
    return true;
}

function sort_json(){
    var sorted = {};
    Object.keys(_fee_by_currency).sort().forEach(function(key) {
        sorted[key] = _fee_by_currency[key];
    });
    _fee_by_currency = sorted;
    document.getElementById("fee_by_currency").value = JSON.stringify(_fee_by_currency, null, 2);
}

/* 
Checks if all default fees are valid
*/
function validate_input(){
    document.getElementById("currency_msg").innerHTML = '';
    var default_valid = validate_fee(document.getElementById("fiat_fiat").value, "fiat-fiat") && 
    validate_fee(document.getElementById("fiat_crypto").value, "fiat-crypto") && 
    validate_fee(document.getElementById("fiat_stable").value, "fiat-stable") &&
    validate_fee(document.getElementById("crypto_fiat").value, "crypto_fiat") &&
    validate_fee(document.getElementById("stable_fiat").value, "stable_fiat");
    
    if (!default_valid)
        return false;
    
    var key_list = [];
    var fees_json;
    try{
    	fees_json = JSON.parse(document.getElementById("fee_by_currency").value);
    } 
    catch{
    	window.alert("Invalid JSON structure for fees by currency.");
    	return false;
    }
    for (var key in fees_json) 
	    if (fees_json.hasOwnProperty(key)) {
	        var currencies = key.split("_");
	        if (currencies.length != 2 || _all_currencies.indexOf(currencies[0]) < 0 || _all_currencies.indexOf(currencies[1]) < 0 ){
	            window.alert(key+" is not a valid currency pair (e.g. USD_BTC or BTC_AUD).");
	            return false;
	        }
	        if (!validate_fee(String(fees_json[key]), key))
	        	return false;
	        if (key_list.indexOf(key) >= 0){
	        	window.alert(key+" is duplicate.");
	            return false;
	        }
	        key_list.push(key);
	    }
    _fee_by_currency = fees_json;
    sort_json();
	return true;
}

/*
Generates a list of currencies matching the value selected in a currency combo-box.
*/
function get_currency_list(selected_currency){
    switch (selected_currency){
        case 'fiat':
            return _fiat_currencies;
        case 'crypto':
            return _crypto_currencies;
        case 'stable':
            return _stable_currencies;
        case 'all':
            return _all_currencies;
    }
    return [selected_currency];
}

/*
Edits fee_by_currency textarea value by user request for deleting or setting values.
*/
function edit_fee_by_crurrency() {
    document.getElementById("currency_msg").innerHTML = '';
    var currency_array1 = get_currency_list(document.getElementById("first_currency").value);
    var currency_array2 = get_currency_list(document.getElementById("second_currency").value);
    
    var fee = document.getElementById("currency_fee").value;
    if (!validate_fee(fee, 'Fee Per Currency'))
        return;
    
    for (cur1 of currency_array1)
        for (cur2 of currency_array2)
            _fee_by_currency[cur1+"_"+cur2] = Number(fee);

    sort_json();
}

/*
Sets up the elements included in the HTML from at startup.
We are going to edit transfer fees from <first_currency> to <second_currency>, represented by two option elements.
The result is displayed in the <fee_by_currency> textarea.
*/
function initialize_values(){ 
    document.getElementById("fee_by_currency").value = JSON.stringify(_fee_by_currency, null, 2);
    
    for(cur of _all_currencies){
         var option = document.createElement('option');
         option.text = cur;
         document.getElementById('first_currency').add(option);
         document.getElementById('second_currency').add(option.cloneNode(true));
     }
    
    option = document.createElement('option');
    option.text = 'fiat';
    document.getElementById('first_currency').add(option);
    document.getElementById('second_currency').add(option.cloneNode(true));
    
    option = document.createElement('option');
    option.text = 'crypto';
    document.getElementById('first_currency').add(option);
    document.getElementById('second_currency').add(option.cloneNode(true));
    
    option = document.createElement('option');
    option.text = 'stable';
    document.getElementById('first_currency').add(option);
    document.getElementById('second_currency').add(option.cloneNode(true));
    
    option = document.createElement('option');
    option.text = 'all';
    document.getElementById('first_currency').add(option);
    document.getElementById('second_currency').add(option.cloneNode(true));
    
    document.getElementById("first_currency").selectedIndex = "0";
    document.getElementById("second_currency").selectedIndex = "0";
    
    document.getElementById("fiat_fiat").value = _fiat_fiat;
    document.getElementById("fiat_crypto").value = _fiat_crypto;
    document.getElementById("fiat_stable").value = _fiat_stable;
    document.getElementById("crypto_fiat").value = _crypto_fiat;
    document.getElementById("stable_fiat").value = _stable_fiat;
};

window.onload = initialize_values;
</script>

<form id="fees_form" name="fees_form" action="$action" onsubmit="return validate_input()" method="post">
<input type="hidden" name='_form_submit' value='_form_submit'></input>
<p style='color:black'><strong>DEFAULT VALIES</strong></p>
<div  id='default_msg'>$defaults_msg</div>
<table>
	<tr><td>fiat-fiat: </td><td>  <input type="text" size="10" name="fiat_fiat" id="fiat_fiat" /></td></tr>
	<tr><td>fiat-crypto: </td><td>  <input type="text" size="10" name="fiat_crypto" id="fiat_crypto" /></td></tr>
	<tr><td>fiat-stable: </td><td>  <input type="text" size="10" name="fiat_stable" id="fiat_stable" /></td></tr>
	<tr><td>crypto_fiat: </td><td>  <input type="text" size="10" name="crypto_fiat" id="crypto_fiat" /></td></tr>
	<tr><td>stable_fiat: </td><td>  <input type="text" size="10" name="stable_fiat" id="stable_fiat" /></td></tr>
</table>

<p style='color:black'><strong>BY CURRENCY</strong></p>
<div  id='currency_msg'> $currency_msg</div>
<table>
	<tr><td>
            First currency: <select id="first_currency"></select>
	    Second currency: <select id="second_currency"></select>
	    Fee: <input type="text" size="10" id="currency_fee" />
            <button type="button" onclick="edit_fee_by_crurrency()">Set Selected </button>
	</td></tr>
    <tr><td>
        <textarea id="fee_by_currency" name="fee_by_currency" rows="20" cols="40" form="fees_form"></textarea>
    </td></tr>
    <tr><td>
        <input type="submit" name='submit' value='Apply Changes'></input>
    </td></tr>
</table> 

</form>
~;

code_exit_BO();

