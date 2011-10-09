# See LICENSE for licensing information.

DIALYZER = dialyzer
REBAR = rebar

all: app

app: deps
	@$(REBAR) compile

deps:
	@$(REBAR) get-deps

clean:
	@$(REBAR) clean
	rm -f test/*.beam
	rm -f erl_crash.dump
	rm -f ebin/*.app
	rm -rf rel/mynode

tests: clean app eunit ct

eunit:
	@$(REBAR) eunit skip_deps=true

ct:
	@$(REBAR) ct

build-plt:
	@$(DIALYZER) --build_plt --output_plt .agilitycache_dialyzer.plt \
		--apps kernel stdlib sasl inets

dialyze:
	@$(DIALYZER) --src --plt .agilitycache_dialyzer.plt \
		-Wbehaviours -Werror_handling \
		-Wrace_conditions -Wunmatched_returns -r apps
		

docs:
	@$(REBAR) doc

generate: app
	@$(REBAR) generate
