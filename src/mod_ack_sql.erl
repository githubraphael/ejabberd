%%%-------------------------------------------------------------------
%%% File    : mod_offline_sql.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created : 15 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2023   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_ack_sql).


-behaviour(mod_message_ack).

-export([init/2]).
-export([add_event/5]).

-include_lib("xmpp/include/xmpp.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ok.

%%% 日志信息， ip,event,account,time
%%% 登录失败，登录成功，重试次数
add_event(LServer, User, Ip, Event, Time) ->
%%    ?INFO_MSG("add_eventadd_eventadd_eventadd_eventadd_event", []),
    ejabberd_sql:sql_query(
        LServer,
        ?SQL_INSERT(
            "user_events",
            ["user=%(User)s",
            "ip=%(Ip)s",
            "event=%(Event)s",
            "timestamp=%(Time)d"])).

remove_all_events(LUser, LServer) ->
    ejabberd_sql:sql_query(
        LServer,
        ?SQL("delete from archive where username=%(LUser)s and %(LServer)H")),
    ejabberd_sql:sql_query(
        LServer,
        ?SQL("delete from archive_prefs where username=%(LUser)s and %(LServer)H")).