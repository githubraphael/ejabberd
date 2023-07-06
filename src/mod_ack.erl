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

-export([start/2, stop/1, reload/3, c2s_auth_result/3, c2s_stream_started/2]).

-export([mod_opt_type/1, mod_options/1, mod_doc/0, depends/2]).
-export([on_user_send_packet/1, reject_unauthenticated_packet/2, process_terminated/2]).
-export([c2s_session_opened/1, c2s_session_resumed/1, c2s_handle_info/2, c2s_closed/2]).
-export([init/1, terminate/2, get_commands_spec/0]).
-export([demo_api/1,user_resources/2]).

-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").
-include("ejabberd_commands.hrl").
-include("ejabberd_http.hrl").
-include("translate.hrl").

%% default value for the maximum number of user messages

-record(state, {host = <<"">> :: binary()}).
-type c2s_state() :: ejabberd_c2s:state().
-type state() :: xmpp_stream_in:state().
-export_type([state/0]).
-import(string, [substr/3]).

depends(_Host, _Opts) ->
  [].

start(Host, Opts) ->
  Mod = gen_mod:db_mod(Opts, ?MODULE),
  Mod:init(Host, Opts),
  init_cache(Mod, Host, Opts),
  %  注册api定义
  ejabberd_commands:register_commands(?MODULE, get_commands_spec()),
  %% 回调相关的代码
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE, on_user_send_packet, 0),
  ejabberd_hooks:add(c2s_auth_result, Host, ?MODULE, c2s_auth_result, 100),
  %% 日志相关的代码
  ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 51),
  ejabberd_hooks:add(c2s_session_resumed, Host, ?MODULE, c2s_session_resumed, 50),
  ejabberd_hooks:add(forbidden_session_hook, Host, ?MODULE, forbidden_session_hook, 100),
  ejabberd_hooks:add(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 50),
  ejabberd_hooks:add(c2s_stream_started, Host, ?MODULE, c2s_stream_started, 100),
  ejabberd_hooks:add(c2s_closed, Host, ?MODULE, c2s_closed, 50),
  ejabberd_hooks:add(c2s_terminated, Host, ?MODULE, process_terminated, 100),
  ejabberd_hooks:add(c2s_unauthenticated_packet, Host, ?MODULE, reject_unauthenticated_packet, 100).
%%  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  % 取消api定义
  case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
      false ->
          ejabberd_commands:unregister_commands(get_commands_spec());
      true ->
          ok
  end,
  %% 回调相关的代码
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, on_user_send_packet, 0),
  ejabberd_hooks:delete(c2s_auth_result, Host, ?MODULE, c2s_auth_result, 100),
  %% 日志相关的代码
  ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 51),
  ejabberd_hooks:delete(c2s_session_resumed, Host, ?MODULE, c2s_session_resumed, 50),
  ejabberd_hooks:delete(forbidden_session_hook, Host, ?MODULE, forbidden_session_hook, 100),
  ejabberd_hooks:delete(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 50),
  ejabberd_hooks:delete(c2s_stream_started, Host, ?MODULE, c2s_stream_started, 100),
  ejabberd_hooks:delete(c2s_closed, Host, ?MODULE, c2s_closed, 50),
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
  ets_cache:new(mod_ack_prefix_cache),
  ets_cache:insert(mod_ack_prefix_cache,prefix, mod_ack_opt:prefix(Opts)).

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
on_user_send_packet({#message{to= #jid{luser = ToUser,
				    lserver = ToServer} = To, from = From, type = Type, id = ID, body = Body} = Packet, C2SState}) ->
%%  ?DEBUG("mod_stanza_ack a message has been sent coming from: ~p", [From]),
%%  ?DEBUG("mod_stanza_ack a message has been sent to: ~p", [To]),
  ?DEBUG("mod_stanza_ack a message has been sent with the following packet:~n ~p", [fxml:element_to_binary(xmpp:encode(Packet))]),
  %%% 给消息发送人，发送消息回执
  BodyTxt = xmpp:get_text(Body),
  %% 读取需要ack的配置内容
  {_,AckMsgPrefix} = ets_cache:lookup(mod_ack_prefix_cache, prefix),
  ?DEBUG("ack message`s regex is ->  ~p", [AckMsgPrefix]),
%%  AckMsgPrefix = <<"^(\{|a|c|p|k)">>,
%%  case chr(BodyTxt, ${) == 1 of
  case re:run(binary_to_list(BodyTxt), AckMsgPrefix, [{capture, none}]) of
    %% 服务端接收到普通消息，发送ack消息
    match ->
      To2 = jid:encode(From),
      DeliveredFrom = jid:encode(To),
      From2 = list_to_binary("1000@localhost"),
      %% 即使为群消息，也是通过1对1消息，发送确认
      Type2 = <<"chat">>,
      %%atom_to_binary(Type)
      CodecOpts = ejabberd_config:codec_options(),
      %% 如果接收用户在线；不管对方是否接收到，均设置为已发送；因为这个可靠性，由服务器负责。
      Delivered = case length(user_resources(ToUser, ToServer))  of
	      N when N =< 0 -> <<"false">>;
        N -> <<"true">>
      end,
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
              #xmlel{name = <<"delivered">>,
                attrs = [
                  {<<"from">>, DeliveredFrom}
                ],
                children = [{xmlcdata, Delivered}]},
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
          ?DEBUG("Acked to Sending Side: Xml -> ~p -> To: ~p", [
            fxml:element_to_binary(xmpp:encode(Msg)), To
          ]),
          ejabberd_router:route(Msg)
      catch
        _:{xmpp_codec, Why} ->
          {error, xmpp:format_error(Why)}
      end;
    nomatch -> ?DEBUG("current message is not valid message.", [])
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
-spec user_resources(binary(), binary()) -> [binary()].
user_resources(User, Server) ->
    ejabberd_sm:get_user_resources(User, Server).

-spec c2s_auth_result(ejabberd_c2s:state(), true | {false, binary()}, binary())
      -> ejabberd_c2s:state() | {stop, ejabberd_c2s:state()}.
c2s_auth_result(#{sasl_mech := Mech} = State, {false, _}, _User)
  when Mech == <<"EXTERNAL">> ->
  State;
c2s_auth_result(#{ip := {Addr, _}, lserver := LServer} = State, {false, _}, _User) ->
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([_User, <<"@">>, LServer]), client_info(State, Addr), <<"Auth failed">>, integer_to_binary(current_time())),
  State;
c2s_auth_result(#{ip := {Addr, _}, lserver := LServer} = State, true, _User) ->
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([_User, <<"@">>, LServer]), client_info(State, Addr), <<"Auth successed">>, integer_to_binary(current_time())),
  State.
%% 连接被拒绝
reject_unauthenticated_packet(#{ip := {Addr, _}, lserver := LServer} = State, _Pkt) ->
  Time = current_time(),
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([LServer]), client_info(State, Addr), <<"Auth rejected">>, integer_to_binary(Time)).

%% 授权通过
-spec c2s_session_opened(c2s_state()) -> c2s_state().
c2s_session_opened(#{ip := {Addr, _}, user := U, server := LServer, resource := R} = State) ->
  JID = jid:make(U, LServer, R),
  Time = current_time(),
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([jid:encode(JID)]), client_info(State, Addr), <<"C2s session opened">>, integer_to_binary(Time)),
  State;
c2s_session_opened(State) ->
  State.

c2s_session_resumed(#{ip := {Addr, _}, user := U, server := LServer, resource := R} = State) ->
  JID = jid:make(U, LServer, R),
  Time = current_time(),
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([jid:encode(JID)]), client_info(State, Addr), <<"C2s session resumed">>, integer_to_binary(Time)),
  State.

forbidden_session_hook(#{ip := {Addr, _}, user := U, server := LServer, resource := R} = State) ->
  JID = jid:make(U, LServer, R),
  Time = current_time(),
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([jid:encode(JID)]), client_info(State, Addr), <<"C2s session forbidden">>, integer_to_binary(Time))
.

c2s_handle_info(#{mgmt_ack_timer := TRef, server := LServer, ip := {Addr, _}, jid := JID} = State,
    {timeout, TRef, ack_timeout}) ->
  Time = current_time(),
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([jid:encode(JID)]), client_info(State, Addr), <<"Timed out waiting for stream management acknowledgement">>, integer_to_binary(Time)),
  transition_to_pending(State, ack_timeout),
  State;
c2s_handle_info(#{mgmt_state := pending, lang := Lang, server := LServer,
  mgmt_pending_timer := TRef, ip := {Addr, _}, jid := JID} = State,
    {timeout, TRef, pending_timeout}) ->
  Time = current_time(),
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([jid:encode(JID)]), client_info(State, Addr), <<"Timed out waiting for resumption of stream">>, integer_to_binary(Time)),
  State;
c2s_handle_info(State, {_Ref, {resume, #{ip := {Addr, _}, jid := JID, server := LServer} = OldState}}) ->
  %% This happens if the resume_session/1 request timed out; the new session
  %% now receives the late response.
  Time = current_time(),
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([jid:encode(JID)]), client_info(State, Addr), <<"Timed out waiting for resumption of stream">>, integer_to_binary(Time)),
  State;
c2s_handle_info(State, {timeout, _, Timeout}) when Timeout == ack_timeout;
  Timeout == pending_timeout ->
  %% Late arrival of an already cancelled timer: we just ignore it.
  %% This might happen because misc:cancel_timer/1 doesn't guarantee
  %% timer cancellation in the case when p1_server is used.
  State;
c2s_handle_info(State, _) ->
  State.

-spec transition_to_pending(state(), _) -> state().
transition_to_pending(#{mgmt_state := active, mod := Mod,
  mgmt_timeout := 0} = State, _Reason) ->
  State;
transition_to_pending(#{mgmt_state := active, ip := {Addr, _}, jid := JID, socket := Socket,
  lserver := LServer, mgmt_timeout := Timeout} = State,
    Reason) ->
  Time = current_time(),
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:add_event(LServer, list_to_binary([jid:encode(JID)]), client_info(State, Addr), list_to_binary([<<"Closing c2s connection -> waiting ">>, integer_to_binary(Timeout div 1000), <<" seconds for stream resumption">>]), integer_to_binary(Time)),
  State;
transition_to_pending(State, _Reason) ->
  State.

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
c2s_stream_started(#{ip := {Addr, _}, user := User, stream_authenticated := Authenticated, lserver := LServer} = State, Stream2) ->
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Time = current_time(),
  Mod:add_event(LServer, list_to_binary([User, <<"@">>, LServer]), client_info(State, Addr), list_to_binary([<<"Stream started -> Authenticated:">>, atom_to_binary(Authenticated)]), integer_to_binary(Time)),
  State.

c2s_closed(State, {stream, _}) ->
  State;
c2s_closed(#{mgmt_state := active} = State, Reason) ->
  transition_to_pending(State, Reason),
  State;
c2s_closed(State, _Reason) ->
  State.

process_terminated(#{ip := {Addr, _}, sid := SID, jid := JID, user := U, server := S, resource := R} = State,
    Reason) ->
  Status = format_reason(State, Reason),
  Time = current_time(),
  Mod = gen_mod:db_mod(S, ?MODULE),
  Mod:add_event(S, jid:encode(JID), client_info(State, Addr), list_to_binary([<<"Closing c2s session ->">>, Status]), integer_to_binary(Time)),
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
  econf:shaper();
mod_opt_type(prefix) ->
  econf:either(auto, econf:string()).

mod_options(_Host) ->
  [{db_type, db_type},
    {prefix, prefix}].

mod_doc() ->
  #{
    desc =>
    ?T("This is an example module.")
  }.

%%%
%%% ejabberd commands
%%%

demo_api(ServiceArg) ->
    ?INFO_MSG("----------> ~p", [ServiceArg]),
    % throw({error, "Internal error"}).
    "xxxxx".

get_commands_spec() ->
    [
     #ejabberd_commands{name = user_is_active, tags = [muc],
		       desc = "获取某个用户最后通讯时间；如果时间逐个短，表示当前用户仍然在线！",
           policy = admin,
		       module = ?MODULE, function = demo_api,
		       args_desc = ["MUC service, or 'global' for all"],
		       args_example = ["args_example"],
		       result_desc = "result_desc",
		       result_example = ["result_example"],
		       args = [{name, binary}],
		       args_rename = [{host, service}],
          %  result = {res, string}}
		       result = {res, rescode}}
    ].