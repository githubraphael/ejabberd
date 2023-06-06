%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_ack_opt).

-export([access_max_user_messages/1]).

-spec access_max_user_messages(gen_mod:opts() | global | binary()) -> atom() | [ejabberd_shaper:shaper_rule()].
access_max_user_messages(Opts) when is_map(Opts) ->
    gen_mod:get_opt(access_max_user_messages, Opts);
access_max_user_messages(Host) ->
    gen_mod:get_module_opt(Host, mod_message_ack, access_max_user_messages).

