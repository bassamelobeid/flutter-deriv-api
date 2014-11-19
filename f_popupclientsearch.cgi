#!/usr/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
system_initialize();

PrintContentType();

BOM::Platform::Auth0::can_access(['CS']);

my $broker_options = '';
my $runtime        = BOM::Platform::Runtime->instance;
foreach my $broker (map { $_->code } $runtime->broker_codes->get_brokers_on_server($runtime->hosts->localhost)) {
    $broker_options .= "<option value='$broker'>$broker</option>";
}

print qq~
<head>
    <title>Client Search</title>
</head>
<body>
<center><font size="2" face="verdana">
<strong>Client Search</strong>
<br />
<form action="~ . request()->url_for('backoffice/f_popupclientsearch_doit.cgi') . qq~" method="post">
	<input type="text" size="10" name="partialfname" value="Partial FName" onfocus="this.select()" />
        <input type="text" size="10" name="partiallname" value="Partial LName" onfocus="this.select()" />
	<input type="text" size="20" name="partialemail" value="Partial email" onfocus="this.select()" />

    <select name = "broker">
        <option value="FOG" selected="selected">ALL</option>
        ~ . $broker_options . qq~
    </select>

	<input type="submit" value="Search" />
</form>
<p>Note: For best results, enter either only the Client's first name or last name</p>

</body>~;

code_exit_BO();
