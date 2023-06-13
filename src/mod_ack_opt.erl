%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_ack_opt).

-export([db_type/1]).
-export([prefix/1]).

-spec db_type(gen_mod:opts() | global | binary()) -> atom() | [ejabberd_shaper:shaper_rule()].
db_type(Opts) when is_map(Opts) ->
    gen_mod:get_opt(db_type, Opts);
db_type(Host) ->
    gen_mod:get_module_opt(Host, mod_ack, db_type).

-spec prefix(gen_mod:opts() | global | binary()) -> 'auto' | 'prefix' | string().
prefix(Opts) when is_map(Opts) ->
    gen_mod:get_opt(prefix, Opts);
prefix(Host) ->
    gen_mod:get_module_opt(Host, mod_ack, prefix).

