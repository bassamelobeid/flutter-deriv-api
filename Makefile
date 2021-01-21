SUBDIRS=$(wildcard /home/git/regentmarkets/*) $(wildcard /home/git/binary-com/*)
M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -lrv -It/lib -MTest::Warnings
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(SUBDIRS)

$(SUBDIRS):
	@if [ -d $@ ] && [ -f $@/Makefile ] && grep -q '^test:' $@/Makefile; then $(MAKE) -C $@ test; else echo Skipping $@; fi

# we exclude /WebsocketAPI/{Tests,Helpers} here to prevent the Future chains from being mangled into an unreadable mess
tidy:
	find . -name '*.p?.bak' -delete
	find lib t \( -name '*.p[lm]'  -o -name '*.t' \) -not \( -path '*/WebsocketAPI/Tests/*' -o -path '*/WebsocketAPI/Helpers/*' \) | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	@$(PROVE) t/BOM t/bin

syntax:
	@$(PROVE) t/*.t

doc:
	pod2markdown lib/BOM/Test.pm > README.md

.PHONY: test $(SUBDIRS) test_all doc tidy
