DIALYZER = dialyzer
REBAR=`which rebar || ./rebar`

all: deps compile

deps:
	    @$(REBAR) get-deps
compile:
	    @$(REBAR) compile
test:
	    @$(REBAR) skip_deps=true eunit
clean:
	    @$(REBAR) clean
			
build-plt:
	@$(DIALYZER) --build_plt --output_plt .agilitycache_dialyzer.plt \
		--apps kernel stdlib sasl erts ssl \
		tools os_mon runtime_tools crypto \
		inets \
		eunit syntax_tools compiler

dialyze:
	@$(DIALYZER) --src --plt .agilitycache_dialyzer.plt \
		-Wunmatched_returns \
		-Werror_handling \
		-Wrace_conditions \
		-Wbehaviours \
		-Wunderspecs \
		-r apps

docs:
	@$(REBAR) doc

generate: deps compile
	@$(REBAR) generate

.PHONY: all test clean deps docs
