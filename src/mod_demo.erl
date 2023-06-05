-module(mod_demo).

-behaviour(gen_mod).

-define(SPOOL_COUNTER_CACHE, offline_msg_counter_cache).


%% Required by ?INFO_MSG macros
-include("logger.hrl").

%% Required by ?T macro
-include("translate.hrl").
-include_lib("xmpp/include/xmpp.hrl").

-include("mod_offline.hrl").

%% gen_mod API callbacks
-export([start/2, stop/1, reload/3, depends/2, mod_opt_type/1, mod_options/1, mod_doc/0]).
-export([on_user_send_packet/1]).
-export([store_user_message_packet/1]).

-define(PRINT2(Format, Args), io:format(Format, Args)).

start(Host, Opts) ->
  Mod = gen_mod:db_mod(Opts, ?MODULE),
  Mod:init(Host, Opts),
  ?INFO_MSG("mod_stanza_ack starting", []),
  ejabberd_hooks:add(store_user_message_hook, Host, ?MODULE, store_user_message_packet, 0),
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE, on_user_send_packet, 0),
  ok.

stop(Host) ->
  ?INFO_MSG("mod_stanza_ack stopping", []),
  ejabberd_hooks:add(store_user_message_hook, Host, ?MODULE, store_user_message_packet, 0),
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, on_user_send_packet, 0),
  ok.

reload(Host, NewOpts, OldOpts) ->
  NewMod = gen_mod:db_mod(NewOpts, ?MODULE),
  OldMod = gen_mod:db_mod(OldOpts, ?MODULE),
  if NewMod /= OldMod ->
    NewMod:init(Host, NewOpts);
    true ->
      ok
  end.

% 将消息保存到spool表中，等待用户确认
-spec store_user_message_packet({any(), message()}) -> {any(), message()}.
store_user_message_packet({_Action, #message{from = From, to = To} = Packet} = Acc) ->
  ?INFO_MSG("store packet waiting to ack", []),
  case need_to_store(To#jid.lserver, Packet) of
    true ->
      ?INFO_MSG("store packet waiting to ack need_to_store 1", []),
      case check_event(Packet) of
        true ->
          #jid{luser = LUser, lserver = LServer} = To,
          TimeStamp = erlang:timestamp(),
          Expire = find_x_expire(TimeStamp, Packet),
          OffMsg = #offline_msg{us = {LUser, LServer},
            timestamp = TimeStamp,
            expire = Expire,
            from = From,
            to = To,
            packet = Packet},
          case store_offline_msg(OffMsg) of
            ok ->
              {offlined, Packet};
            {error, Reason} ->
              discard_warn_sender(Packet, Reason),
              stop
          end
      end
  end.

-spec store_offline_msg(#offline_msg{}) -> ok | {error, full | any()}.
store_offline_msg(#offline_msg{us = {User, Server}, packet = Pkt} = Msg) ->
  UseMam = use_mam_for_user(User, Server),
  Mod = gen_mod:db_mod(Server, ?MODULE),
  ?INFO_MSG("xmpp:get_meta(Pkt, mam_archived, false)   ---> ~p", [Pkt]),
  store_message_in_db(Mod, Msg).

-spec store_message_in_db(module(), #offline_msg{}) -> ok | {error, any()}.
store_message_in_db(Mod, #offline_msg{us = {User, Server}} = Msg) ->
  case Mod:store_message(Msg) of
    ok ->
      ?INFO_MSG("Save Message To Db Sucessfully",[]);
    Err ->
      Err
  end.

-spec discard_warn_sender(message(), full | any()) -> ok.
discard_warn_sender(Packet, Reason) ->
  case check_if_message_should_be_bounced(Packet) of
    true ->
      Lang = xmpp:get_lang(Packet),
      Err = case Reason of
              full ->
                ErrText = ?T("Your contact offline message queue is "
                "full. The message has been discarded."),
                xmpp:err_resource_constraint(ErrText, Lang);
              _ ->
                ErrText = ?T("Database failure"),
                xmpp:err_internal_server_error(ErrText, Lang)
            end,
      ejabberd_router:route_error(Packet, Err);
    _ ->
      ok
  end.

-spec need_to_store(binary(), message()) -> boolean().
need_to_store(_LServer, #message{type = error}) -> false;
need_to_store(LServer, #message{type = Type} = Packet) ->
  case xmpp:has_subtag(Packet, #offline{}) of
    false ->
      case misc:unwrap_mucsub_message(Packet) of
        #message{type = groupchat} = Msg ->
          need_to_store(LServer, Msg#message{type = chat});
        #message{} = Msg ->
          need_to_store(LServer, Msg);
        _ ->
          case check_store_hint(Packet) of
            store ->
              true;
            no_store ->
              false;
            none ->
              Store = case Type of
                        groupchat ->
                          mod_offline_opt:store_groupchat(LServer);
                        headline ->
                          false;
                        _ ->
                          true
                      end,
              case {misc:get_mucsub_event_type(Packet), Store,
                mod_offline_opt:store_empty_body(LServer)} of
                {?NS_MUCSUB_NODES_PRESENCE, _, _} ->
                  false;
                {_, false, _} ->
                  false;
                {_, _, true} ->
                  true;
                {_, _, false} ->
                  Packet#message.body /= [];
                {_, _, unless_chat_state} ->
                  not misc:is_standalone_chat_state(Packet)
              end
          end
      end;
    true ->
      false
  end.

-spec check_store_hint(message()) -> store | no_store | none.
check_store_hint(Packet) ->
  case has_store_hint(Packet) of
    true ->
      store;
    false ->
      case has_no_store_hint(Packet) of
        true ->
          no_store;
        false ->
          none
      end
  end.

-spec has_store_hint(message()) -> boolean().
has_store_hint(Packet) ->
  xmpp:has_subtag(Packet, #hint{type = 'store'}).

-spec has_no_store_hint(message()) -> boolean().
has_no_store_hint(Packet) ->
  xmpp:has_subtag(Packet, #hint{type = 'no-store'})
    orelse
    xmpp:has_subtag(Packet, #hint{type = 'no-storage'}).

%% Check if the packet has any content about XEP-0022
-spec check_event(message()) -> boolean().
check_event(#message{from = From, to = To, id = ID, type = Type} = Msg) ->
  case xmpp:get_subtag(Msg, #xevent{}) of
    false ->
      true;
    #xevent{id = undefined, offline = false} ->
      true;
    #xevent{id = undefined, offline = true} ->
      NewMsg = #message{from = To, to = From, id = ID, type = Type,
        sub_els = [#xevent{id = ID, offline = true}]},
      ejabberd_router:route(NewMsg),
      true;
    % Don't store composing events
    #xevent{id = V, composing = true} when V /= undefined ->
      false;
    % Nor composing stopped events
    #xevent{id = V, composing = false, delivered = false,
      displayed = false, offline = false} when V /= undefined ->
      false;
    % But store other received notifications
    #xevent{id = V} when V /= undefined ->
      true;
    _ ->
      false
  end.

-spec find_x_expire(erlang:timestamp(), message()) -> erlang:timestamp() | never.
find_x_expire(TimeStamp, Msg) ->
  case xmpp:get_subtag(Msg, #expire{seconds = 0}) of
    #expire{seconds = Int} ->
      {MegaSecs, Secs, MicroSecs} = TimeStamp,
      S = MegaSecs * 1000000 + Secs + Int,
      MegaSecs1 = S div 1000000,
      Secs1 = S rem 1000000,
      {MegaSecs1, Secs1, MicroSecs};
    false ->
      never
  end.

use_mam_for_user(_User, Server) ->
  mod_offline_opt:use_mam_for_storage(Server).

-spec check_if_message_should_be_bounced(message()) -> boolean().
check_if_message_should_be_bounced(Packet) ->
  case Packet of
    #message{type = groupchat, to = #jid{lserver = LServer}} ->
      mod_offline_opt:bounce_groupchat(LServer);
    #message{to = #jid{lserver = LServer}} ->
      case misc:is_mucsub_message(Packet) of
        true ->
          mod_offline_opt:bounce_groupchat(LServer);
        _ ->
          true
      end;
    _ ->
      true
  end.

% 展示消息发送的日志信息
on_user_send_packet({#presence{to = To, from = From} = Packet, C2SState}) ->
  ?INFO_MSG("mod_stanza_ack a presence has been sent coming from: ~p", [From]),
  ?INFO_MSG("mod_stanza_ack a presence has been sent to: ~p", [To]),
  ?INFO_MSG("mod_stanza_ack a presence has been sent with the following packet:~n ~p", [Packet]),
  {Packet, C2SState};
on_user_send_packet({#iq{to = To, from = From} = Packet, C2SState}) ->
  ?INFO_MSG("mod_stanza_ack a iq has been sent coming from: ~p", [From]),
  ?INFO_MSG("mod_stanza_ack a iq has been sent to: ~p", [To]),
  ?INFO_MSG("mod_stanza_ack a iq has been sent with the following packet:~n ~p", [Packet]),
  {Packet, C2SState};
on_user_send_packet({#message{to = To, from = From} = Packet, C2SState}) ->
  ?INFO_MSG("mod_stanza_ack a message has been sent coming from: ~p", [From]),
  ?INFO_MSG("mod_stanza_ack a message has been sent to: ~p", [To]),
  ?INFO_MSG("mod_stanza_ack a message has been sent with the following packet:~n ~p", [Packet]),
  %%% 发送消息回执（告诉客户端，服务器已经收到消息了）
  XmlBody =
    {xmlelement, "message", [{"id", []}, {"type", "normal"}, {"from", From}, {"to", To}], [
      {xmlelement, "body", [], [{xmlcdata, <<"Test Message">>}]}
    ]},
  % NewPacket = xmpp:set_from_to(XmlBody, To, From),
  % ejabberd_router:route(To, From, XmlBody),
  % mod_admin_extra:send_message(list_to_binary("chat"),list_to_binary("1000003@localhost"),list_to_binary("1000002@localhost"),list_to_binary(""), list_to_binary("nddd")),
  To2 = list_to_binary("1000002@localhost"),
  From2 = list_to_binary("1000@localhost"),
  Type = list_to_binary("chat"),
  Subject = list_to_binary("sdsd"),
  Body = list_to_binary("44"),
  CodecOpts = ejabberd_config:codec_options(),
  try
    xmpp:decode(
      #xmlel{
        name = <<"message">>,
        attrs = [
          {<<"to">>, To2},
          {<<"from">>, From2},
          {<<"type">>, Type},
          {<<"id">>, p1_rand:get_string()}
        ],
        children =
        [
          #xmlel{
            name = <<"action">>,
            children = [{xmlcdata, <<"ServerReceived">>}]
          }
        ]
      },
      ?NS_CLIENT,
      CodecOpts
    )
  of
    #message{from = JID} = Msg ->
      T = Msg#message{},
      % T = xmpp:set_id(T,<<"ididid">>),
      El = xmpp:encode(Msg),
      % El2 = xmpp:encode(T),
      % Xml = fxml:to_xmlel(El, [{elem, <<"appsource">>}, {attr, <<"appid">>}]),
      ?INFO_MSG("sending Xml -> ~p -> ", [
        fxml:element_to_binary(El)
      ]),
      % ejabberd_hooks:run_fold(user_send_packet, JID#jid.lserver, {Msg2, State}, []),
      ejabberd_router:route(Msg),
      ejabberd_router:route(T)
  catch
    _:{xmpp_codec, Why} ->
      {error, xmpp:format_error(Why)}
  end,
  {Packet, C2SState}.

depends(_Host, _Opts) ->
  [].

mod_opt_type(db_type) ->
  econf:db_type(?MODULE).

mod_options(Host) ->
  [{db_type, ejabberd_config:default_db(Host, ?MODULE)}].

mod_doc() ->
  #{
    desc =>
    ?T("This is an example module.")
  }.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%%%

%%%===================================================================
%%% API
%%%===================================================================
%%%
