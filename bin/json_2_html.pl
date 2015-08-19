use JSON;
use File::Slurp;
use Data::Dumper;


opendir(my $dh, 'config/v1') || die;
my @f = ();
while(my $f = readdir $dh) {
	next if ($f eq '.' or $f eq '..');

	push @f, "config/v1/$f";
}

foreach my $f (@f) {
	print_doc_send(JSON::from_json(File::Slurp::read_file("$f/send.json")));
	print "<br><br>";
	print_doc_receive(JSON::from_json(File::Slurp::read_file("$f/receive.json")));    
	print "<hr>";

}

sub print_doc_receive {
	my $data = shift;
	print "<h1>".$data->{title}, "</h1>\n";
	print $data->{description}, "\n";
	print "<pre>{\n";
	for my $p (keys %{$data->{properties}}) {
		if ($data->{properties}->{$p}->{default}) {
			print "\t".$p, ": ", $data->{properties}->{$p}->{default}, ",  // ", $data->{properties}->{$p}->{description}, "\n";
		}else { 
			print "\t".$p, ": ", ",  // ", $data->{properties}->{$p}->{description}, "\n";
		}
		print "\t"."{\n" if (keys %{$data->{properties}->{$p}->{properties}});
		for my $t (keys %{$data->{properties}->{$p}->{properties}}) {
			print	"\t"."\t".$t, ": ", $data->{properties}->{$p}->{properties}->{$t}->{default}, ",  // ", $data->{properties}->{$p}->{properties}->{$t}->{description}, "\n";

		}
		print "\t"."}\n" if (keys %{$data->{properties}->{$p}->{properties}});
	}
	print "}</pre>\n";

}
sub print_doc_send {
	my $data = shift;
	print "<h1>".$data->{title}, "</h1>\n";
	print $data->{description}, "\n";
	print "<pre>{\n";
	for my $p (keys %{$data->{properties}}) {
		print "\t".$p, ": ", $data->{properties}->{$p}->{default}, ",  // ", $data->{properties}->{$p}->{description}, "\n";
	}
	print "}</pre>\n";

}
closedir $dh;