SUBDIRS=$(wildcard /home/git/regentmarkets/*) $(wildcard /home/git/binary-com/*)

test_all: $(SUBDIRS)

$(SUBDIRS):
	@if [ -d $@ ] && [ -f $@/Makefile ] && grep -q '^test:' $@/Makefile; then $(MAKE) -C $@ test; else echo Skipping $@; fi

tidy:
	find . -name '*.p?.bak' -delete
	find lib t \( -name '*.p[lm]'  -o -name '*.t' \) -not \( -path '*/WebsocketAPI/Tests/*' -o -path '*/WebsocketAPI/Helpers/*' \) | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	/etc/rmg/bin/prove -vlr --exec 'perl -Ilib -It/lib -MTest::Warnings' t/

doc:
	pod2markdown lib/BOM/Test.pm > README.md

.PHONY: test $(SUBDIRS) test_all doc tidy
