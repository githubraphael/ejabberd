%%%----------------------------------------------------------------------
%%% 用于处理各种消息的回调，将使消息更靠谱，但也牺牲了性能
%%%----------------------------------------------------------------------

-module(mod_ack).

-import(str, [chr/2]).
-author('simpleman1984@126.com').

-protocol({xep, 13, '1.2', '16.02', "", ""}).
-protocol({xep, 22, '1.4'}).
-protocol({xep, 23, '1.3'}).
-protocol({xep, 160, '1.0'}).
-protocol({xep, 334, '0.2'}).

-behaviour(gen_mod).

-export([start/2, stop/1, reload/3, c2s_auth_result/3,
  c2s_stream_started/2]).

-export([mod_opt_type/1, mod_options/1, mod_doc/0, depends/2]).
-export([on_user_send_packet/1, reject_unauthenticated_packet/2, process_terminated/2]).

-export([init/1, terminate/2]).

-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").

-include("ejabberd_http.hrl").
-include("translate.hrl").

%% default value for the maximum number of user messages
-define(MAX_USER_MESSAGES, infinity).
-define(SPOOL_COUNTER_CACHE, offline_msg_counter_cache).

-record(state, {host = <<"">> :: binary()}).
-type state() :: xmpp_stream_in:state().
-export_type([state/0]).

depends(_Host, _Opts) ->
  [].

start(Host, Opts) ->
  Mod = gen_mod:db_mod(Opts, ?MODULE),
  Mod:init(Host, Opts),
%%  init_cache(Mod, Host, Opts),
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE, on_user_send_packet, 0),
  ejabberd_hooks:add(c2s_auth_result, Host, ?MODULE, c2s_auth_result, 100),
  ejabberd_hooks:add(c2s_stream_started, Host, ?MODULE, c2s_stream_started, 100),
  ejabberd_hooks:add(c2s_terminated, Host, ?MODULE, process_terminated, 100),
  ejabberd_hooks:add(c2s_unauthenticated_packet, Host, ?MODULE, reject_unauthenticated_packet, 100).
%%  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, on_user_send_packet, 0),
  ejabberd_hooks:delete(c2s_auth_result, Host, ?MODULE, c2s_auth_result, 100),
  ejabberd_hooks:delete(c2s_stream_started, Host, ?MODULE, c2s_stream_started, 100),
  ejabberd_hooks:delete(c2s_terminated, Host, ?MODULE,
    process_terminated, 100),
  ejabberd_hooks:delete(c2s_unauthenticated_packet, Host, ?MODULE,
    reject_unauthenticated_packet, 100).
%%  gen_mod:stop_child(?MODULE, Host).

reload(Host, NewOpts, OldOpts) ->
  NewMod = gen_mod:db_mod(NewOpts, ?MODULE),
  OldMod = gen_mod:db_mod(OldOpts, ?MODULE),
  init_cache(NewMod, Host, NewOpts),
  if NewMod /= OldMod ->
    NewMod:init(Host, NewOpts);
    true ->
      ok
  end.

init_cache(Mod, Host, Opts) ->
  true.

%%% 在线发送消息的时候，回执给发送消息的人员
%%% 收到消息有正常的收发消息，也有客户端发送个服务端的ack消息；而这个ack消息是通过user_send_packet进来的。
%%% 1.用户正常发送消息，服务端收到后；需要手动发送一个ack给客户端
%%% 2.用户收到服务端的消息后，手动发送ack给服务端确认，实际上也是user_send_packet事件；只是这个事件比较特殊；服务器应该不进行转发。
on_user_send_packet({#presence{to = To, from = From} = Packet, C2SState}) ->
%%  ?DEBUG("mod_stanza_ack a presence has been sent coming from: ~p", [From]),
%%  ?DEBUG("mod_stanza_ack a presence has been sent to: ~p", [To]),
  ?DEBUG("mod_stanza_ack a presence has been sent with the following packet:~n ~p", [fxml:element_to_binary(xmpp:encode(Packet))]),
  {Packet, C2SState};
on_user_send_packet({#iq{to = To, from = From} = Packet, C2SState}) ->
%%  ?DEBUG("mod_stanza_ack a iq has been sent coming from: ~p", [From]),
%%  ?DEBUG("mod_stanza_ack a iq has been sent to: ~p", [To]),
  ?DEBUG("mod_stanza_ack a iq has been sent with the following packet:~n ~p", [fxml:element_to_binary(xmpp:encode(Packet))]),
  {Packet, C2SState};
on_user_send_packet({#message{to = To, from = From, type = Type, id = ID, body = Body} = Packet, C2SState}) ->
%%  ?DEBUG("mod_stanza_ack a message has been sent coming from: ~p", [From]),
%%  ?DEBUG("mod_stanza_ack a message has been sent to: ~p", [To]),
  ?DEBUG("mod_stanza_ack a message has been sent with the following packet:~n ~p", [fxml:element_to_binary(xmpp:encode(Packet))]),
  %%% 给消息发送人，发送消息回执
  BodyTxt = xmpp:get_text(Body),
  case chr(BodyTxt, ${) == 1 of
    %% 服务端接收到普通消息，发送ack消息
    true ->
      To2 = jid:encode(From),
      From2 = list_to_binary("1000@localhost"),
      %% 即使为群消息，也是通过1对1消息，发送确认
      Type2 = <<"chat">>,
      %%atom_to_binary(Type)
      CodecOpts = ejabberd_config:codec_options(),
      try
        xmpp:decode(
          #xmlel{
            name = <<"message">>,
            attrs = [
              {<<"to">>, To2},
              {<<"from">>, From2},
              {<<"type">>, Type2},
              {<<"id">>, ID}
            ],
            children =
            [
              #xmlel{
                name = <<"body">>,
                children = [{xmlcdata, list_to_binary(["k", ID])}]
              }
            ]
          },
          ?NS_CLIENT,
          CodecOpts
        )
      of
        Msg ->
          ?INFO_MSG("Acked to Sending Side: Xml -> ~p -> To: ~p", [
            fxml:element_to_binary(xmpp:encode(Msg)), To
          ]),
          ejabberd_router:route(Msg)
      catch
        _:{xmpp_codec, Why} ->
          {error, xmpp:format_error(Why)}
      end;
    _ -> ?INFO_MSG("current message is not valid message.", [])
  end,
  {Packet, C2SState}.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%%% 此处的很多逻辑，都是参考的 mod_fail2ban。
init([Host | _]) ->
  process_flag(trap_exit, true),
  ejabberd_hooks:add(c2s_auth_result, Host, ?MODULE, c2s_auth_result, 100),
  ejabberd_hooks:add(c2s_stream_started, Host, ?MODULE, c2s_stream_started, 100).

terminate(_Reason, #state{host = Host}) ->
  ejabberd_hooks:delete(c2s_auth_result, Host, ?MODULE, c2s_auth_result, 100),
  ejabberd_hooks:delete(c2s_stream_started, Host, ?MODULE, c2s_stream_started, 100),
  case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
    true ->
      ok;
    false ->
      ets:delete(failed_auth)
  end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%% 开始处理和连接相关的日志问题
%%%===================================================================
%%% API
%%%===================================================================
-spec c2s_auth_result(ejabberd_c2s:state(), true | {false, binary()}, binary())
      -> ejabberd_c2s:state() | {stop, ejabberd_c2s:state()}.
c2s_auth_result(#{sasl_mech := Mech} = State, {false, _}, _User)
  when Mech == <<"EXTERNAL">> ->
  State;
c2s_auth_result(#{ip := {Addr, _}, lserver := LServer} = State, {false, _}, _User) ->
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([_User,<<"@">>,LServer]), client_info(State, Addr), <<"auth failed">>, integer_to_binary(current_time())),
  State;
c2s_auth_result(#{ip := {Addr, _},lserver := LServer} = State, true, _User) ->
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([_User,<<"@">>,LServer]), client_info(State, Addr), <<"auth successed">>, integer_to_binary(current_time())),
  State.
%% 连接被拒绝
reject_unauthenticated_packet(#{ip := {Addr, _}, lserver := LServer} = State, _Pkt) ->
  Time = current_time(),
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([LServer]), client_info(State, Addr), <<"auth rejected">>, integer_to_binary(Time)).

client_info(State, Addr) ->
  TCP = case maps:find(socket, State) of
          {ok, Socket} -> xmpp_socket:pp(Socket);
          _ -> <<"unknown">>
        end,
  IP = misc:ip_to_list(Addr),
  list_to_binary([TCP, IP]).

current_time() ->
  erlang:system_time(millisecond).

%% 消息的格式化
-spec format_reason(state(), term()) -> binary().
format_reason(#{stop_reason := Reason}, _) ->
  xmpp_stream_in:format_error(Reason);
format_reason(_, normal) ->
  <<"unknown reason">>;
format_reason(_, shutdown) ->
  <<"stopped by supervisor">>;
format_reason(_, {shutdown, _}) ->
  <<"stopped by supervisor">>;
format_reason(_, _) ->
  <<"internal server error">>.

-spec c2s_stream_started(ejabberd_c2s:state(), stream_start())
      -> ejabberd_c2s:state() | {stop, ejabberd_c2s:state()}.
c2s_stream_started(#{ip := {Addr, _}, lserver := LServer} = State, Stream2) ->
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Time = current_time(),
  Mod:add_event(LServer, LServer, client_info(State, Addr), <<"stream_started">>, integer_to_binary(Time)),
  State.

process_terminated(#{ip := {Addr, _}, sid := SID, jid := JID, user := U, server := S, resource := R} = State,
    Reason) ->
  Status = format_reason(State, Reason),
  Time = current_time(),
  Mod = gen_mod:db_mod(S, ?MODULE),
  Mod:add_event(S, jid:encode(JID), client_info(State, Addr), list_to_binary([<<"stream_ended ">>, Status]), integer_to_binary(Time)),
  State;
process_terminated(#{stop_reason := {tls, _}} = State, Reason) ->
  ?WARNING_MSG("(~ts) Failed to secure c2s connection: ~ts",
    [case maps:find(socket, State) of
       {ok, Socket} -> xmpp_socket:pp(Socket);
       _ -> <<"unknown">>
     end, format_reason(State, Reason)]),
  State;
process_terminated(State, _Reason) ->
  State.

mod_opt_type(db_type) ->
  econf:shaper().

mod_options(_Host) ->
  [{db_type, db_type}].

mod_doc() ->
  #{
    desc =>
    ?T("This is an example module.")
  }.
