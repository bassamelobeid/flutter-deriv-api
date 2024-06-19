SUBDIRS=$(wildcard /home/git/regentmarkets/*) $(wildcard /home/git/binary-com/*)
M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -lrv -It/lib -MTest::Warnings
ifeq ($(GITHUB_ACTIONS),true)
	EXTRA_ARGS = --merge --formatter TAP::Formatter::JUnit::PrintTxtStdout
else
	EXTRA_ARGS =
endif
PROVE=p () { $M; echo '$P' $(EXTRA_ARGS) "$$@"; $P $(EXTRA_ARGS) "$$@"; }; p

test_all: $(SUBDIRS)

$(SUBDIRS):
	@if [ -d $@ ] && [ -f $@/Makefile ] && grep -q '^test:' $@/Makefile; then $(MAKE) -C $@ test; else echo Skipping $@; fi

# we exclude /WebsocketAPI/{Tests,Helpers} here to prevent the Future chains from being mangled into an unreadable mess
# TODO we exclude lib/BOM/Test/Rudderstack/Webserver.pm because perltidy cann't handle modules that using Object::Pad class. will fix it after we fix perltidy
tidy:
	find . -name '*.p?.bak' -delete
	find lib t bin \( -name '*.p[lm]'  -o -name '*.t' \) -not \( -path '*/WebsocketAPI/Tests/*' -o -path '*/WebsocketAPI/Helpers/*' \) | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	@$(PROVE) t/BOM

syntax_diff:
	@$(PROVE) --norc $$(ls t/*.t | grep -v syntax_all)

syntax:
	@$(PROVE) --norc t/*.t

doc:
	pod2markdown lib/BOM/Test.pm > README.md

.PHONY: test $(SUBDIRS) test_all doc tidy

unit:
	@$(PROVE) t/unit
