PROJECT := eqm

ERL := erl
EPATH = -pa ebin -pz deps/*/ebin
TEST_EPATH = -pz deps/*/ebin -I deps/proper/include -pa ebin -pa test
PLT_APPS = $(shell ls $(ERL_LIB_DIR) | grep -v interface | sed -e 's/-[0-9.]*//')
DIALYZER_OPTS= -Wno_undefined_callbacks --fullpath

.PHONY: all build_plt compile configure console deps doc clean depclean distclean dialyze release telstart test test-console

all:
	@./rebar skip_deps=true compile

build_plt:
	@dialyzer --build_plt --apps $(PLT_APPS)

compile:
	@./rebar compile

configure:
	@./rebar get-deps compile

console:
	$(ERL) -sname $(PROJECT) $(EPATH)

deps:
	@./rebar get-deps update-deps

doc:
	@./rebar skip_deps=true doc

clean:
	@./rebar skip_deps=true clean

stress: compile
	@erlc -o ./stress ./stress/stress.erl
	@$(ERL) -sname $(PROJECT) $(EPATH) -pa stress

depclean:
	@./rebar clean

distclean:
	@./rebar clean delete-deps
	@rm -rf logs

dialyze:
	@dialyzer $(DIALYZER_OPTS) -r ebin

start:
	$(ERL) -sname $(PROJECT) $(EPATH) -s $(PROJECT)

test-compile:
	@./rebar -C rebar.test.config get-deps compile

test: test-compile
	@./rebar -C rebar.test.config skip_deps=true ct verbose=1

test-console: test-compile
	@erlc $(TEST_EPATH) -o test test/*.erl
	$(ERL) -sname $(PROJECT)_test  $(TEST_EPATH)
