%%%----------------------------------------------------------------------
%%% 用于处理各种消息的回调，将使消息更靠谱，但也牺牲了性能
%%%----------------------------------------------------------------------

-module(mod_ack).

-author('simpleman1984@126.com').

-protocol({xep, 13, '1.2', '16.02', "", ""}).
-protocol({xep, 22, '1.4'}).
-protocol({xep, 23, '1.3'}).
-protocol({xep, 160, '1.0'}).
-protocol({xep, 334, '0.2'}).

-behaviour(gen_mod).

-export([start/2,
  stop/1,
  reload/3]).

-export([mod_opt_type/1, mod_options/1, mod_doc/0, depends/2]).
-export([on_user_send_packet/1]).

-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").

-include("ejabberd_http.hrl").
-include("translate.hrl").

%% default value for the maximum number of user messages
-define(MAX_USER_MESSAGES, infinity).
-define(SPOOL_COUNTER_CACHE, offline_msg_counter_cache).

depends(_Host, _Opts) ->
  [].

start(Host, Opts) ->
%%  Mod = gen_mod:db_mod(Opts, ?MODULE),
%%  Mod:init(Host, Opts),
%%  init_cache(Mod, Host, Opts),
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE, on_user_send_packet, 0).

stop(Host) ->
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, on_user_send_packet, 0).

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
%%  ?INFO_MSG("mod_stanza_ack a presence has been sent coming from: ~p", [From]),
%%  ?INFO_MSG("mod_stanza_ack a presence has been sent to: ~p", [To]),
  ?INFO_MSG("mod_stanza_ack a presence has been sent with the following packet:~n ~p", [fxml:element_to_binary(xmpp:encode(Packet))]),
  {Packet, C2SState};
on_user_send_packet({#iq{to = To, from = From} = Packet, C2SState}) ->
%%  ?INFO_MSG("mod_stanza_ack a iq has been sent coming from: ~p", [From]),
%%  ?INFO_MSG("mod_stanza_ack a iq has been sent to: ~p", [To]),
  ?INFO_MSG("mod_stanza_ack a iq has been sent with the following packet:~n ~p", [fxml:element_to_binary(xmpp:encode(Packet))]),
  {Packet, C2SState};
on_user_send_packet({#message{to = To, from = From, type = Type} = Packet, C2SState}) ->
%%  ?INFO_MSG("mod_stanza_ack a message has been sent coming from: ~p", [From]),
%%  ?INFO_MSG("mod_stanza_ack a message has been sent to: ~p", [To]),
  ?INFO_MSG("mod_stanza_ack a message has been sent with the following packet:~n ~p", [fxml:element_to_binary(xmpp:encode(Packet))]),
  %%% 给消息发送人，发送消息回执
  To2 = jid:encode(From),
  From2 = list_to_binary("1000@localhost"),
  Type2 = atom_to_binary(Type),
  CodecOpts = ejabberd_config:codec_options(),
  try
    xmpp:decode(
      #xmlel{
        name = <<"message">>,
        attrs = [
          {<<"to">>, To2},
          {<<"from">>, From2},
          {<<"type">>, Type2},
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
    Msg ->
      ?INFO_MSG("Acked to Sending Side: Xml -> ~p -> ", [
        fxml:element_to_binary(xmpp:encode(Msg))
      ]),
      ejabberd_router:route(Msg)
  catch
    _:{xmpp_codec, Why} ->
      {error, xmpp:format_error(Why)}
  end,
  {Packet, C2SState}.

mod_opt_type(access_max_user_messages) ->
  econf:shaper().

mod_options(_Host) ->
  [{access_max_user_messages, max_user_offline_messages}].

mod_doc() ->
  #{
    desc =>
    ?T("This is an example module.")
  }.
