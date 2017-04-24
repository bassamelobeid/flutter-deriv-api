test:
	/etc/rmg/bin/prove --exec '/etc/rmg/bin/perl -MTest::FailWarnings=-allow_deps,1 -Ilib/' -lr t/BOM/
