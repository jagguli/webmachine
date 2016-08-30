%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2014 Basho Technologies
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

%% @doc Mochiweb interface for webmachine.
-module(webmachine_mochiweb).
-author('Justin Sheehy <justin@basho.com>').
-author('Andy Gross <andy@basho.com>').
-export([start/1, stop/0, stop/1, loop/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% The `log_dir' option is deprecated, but remove it from the
%% options list if it is present
-define(WM_OPTIONS, [error_handler,
                     log_dir,
                     rewrite_module,
                     resource_module_option]).

-define (WM_OPTION_DEFAULTS, [{error_handler, webmachine_error_handler}]).

start(Options) ->
    {DispatchList, PName, DGroup, WMOptions, OtherOptions} = get_wm_options(Options),
    webmachine_router:init_routes(DGroup, DispatchList),
    _ = [application_set_unless_env_or_undef(K, V) || {K, V} <- WMOptions],
    MochiName = list_to_atom(to_list(PName) ++ "_mochiweb"),
    LoopFun = fun(X) -> loop(DGroup, X) end,
    mochiweb_http:start([{name, MochiName}, {loop, LoopFun} | OtherOptions]).

stop() ->
    {registered_name, PName} = process_info(self(), registered_name),
    MochiName = list_to_atom(atom_to_list(PName) ++ "_mochiweb"),
    stop(MochiName).

stop(Name) ->
    mochiweb_http:stop(Name).

loop(Name, MochiReq) ->
    case webmachine:new_request(mochiweb, MochiReq) of
      {{error, NewRequestError}, ErrorReq} ->
        handle_error(500, {error, NewRequestError}, ErrorReq);
      Req ->
        DispatchList = webmachine_router:get_routes(Name),
        HostHeaders = host_headers(Req),
        Host = host_from_host_values(HostHeaders),
        {Path, _} = Req:path(),
        {RD, _} = Req:get_reqdata(),

        %% Run the dispatch code, catch any errors...
        try webmachine_dispatcher:dispatch(Host, Path, DispatchList, RD) of
            {no_dispatch_match, _UnmatchedHost, _UnmatchedPathTokens} ->
                handle_error(404, {none, none, []}, Req);
            {Mod, ModOpts, HostTokens, Port, PathTokens, Bindings,
             AppRoot, StringPath} ->
                BootstrapResource = webmachine_resource:new(x,x,x,x),
                {ok,RS1} = Req:load_dispatch_data(Bindings,HostTokens,Port,
                                                  PathTokens,AppRoot,StringPath),
                XReq1 = {webmachine_request,RS1},
                try
                    {ok, Resource} = BootstrapResource:wrap(Mod, ModOpts),
                    {ok,RS2} = XReq1:set_metadata('resource_module',
                                                  resource_module(Mod, ModOpts)),
                    webmachine_decision_core:handle_request(Resource, RS2)
                catch
                    error:Error ->
                        handle_error(500, {error, Error}, Req)
                end
        catch
            Type : Error ->
                handle_error(500, {Type, Error}, Req)
        end
    end.

handle_error(Code, Error, Req) ->
    {ok, ErrorHandler} = application:get_env(webmachine, error_handler),
    {ErrorHTML,ReqState1} =
        ErrorHandler:render_error(Code, Req, Error),
    Req1 = {webmachine_request,ReqState1},
    {ok,ReqState2} = Req1:append_to_response_body(ErrorHTML),
    Req2 = {webmachine_request,ReqState2},
    {ok,ReqState3} = Req2:send_response(Code),
    Req3 = {webmachine_request,ReqState3},
    {LogData,_ReqState4} = Req3:log_data(),
    spawn(webmachine_log, log_access, [LogData]).

get_wm_option(OptName, {WMOptions, OtherOptions}) ->
    {Value, UpdOtherOptions} =
        handle_get_option_result(get_option(OptName, OtherOptions), OptName),
    {[{OptName, Value} | WMOptions], UpdOtherOptions}.

handle_get_option_result({undefined, Options}, Name) ->
    {proplists:get_value(Name, ?WM_OPTION_DEFAULTS), Options};
handle_get_option_result(GetOptRes, _) ->
    GetOptRes.

get_wm_options(Options) ->
    {DispatchList, Options1} = get_option(dispatch, Options),
    {Name, Options2} =
        case get_option(name, Options1) of
            {undefined, Opts2} ->
                {webmachine, Opts2};
            NRes -> NRes
        end,
    {DGroup, Options3} =
        case get_option(dispatch_group, Options2) of
            {undefined, Opts3} ->
                {default, Opts3};
            RRes -> RRes
        end,
    {WMOptions, RestOptions} = lists:foldl(fun get_wm_option/2, {[], Options3}, ?WM_OPTIONS),
    {DispatchList, Name, DGroup, WMOptions, RestOptions}.

get_option(Option, Options) ->
    case lists:keytake(Option, 1, Options) of
        false -> {undefined, Options};
        {value, {Option, Value}, NewOptions} -> {Value, NewOptions}
    end.

application_set_unless_env_or_undef(_Var, undefined) ->
    ok;
application_set_unless_env_or_undef(Var, Value) ->
    application_set_unless_env(webmachine, Var, Value).

application_set_unless_env(App, Var, Value) ->
    Current = application:get_all_env(App),
    CurrentKeys = proplists:get_keys(Current),
    case lists:member(Var, CurrentKeys) of
        true ->
            ok;
        false ->
            application:set_env(App, Var, Value)
    end.

%% X-Forwarded-Host/Server can contain comma-separated values.
%% Reference: https://httpd.apache.org/docs/current/mod/mod_proxy.html#x-headers
%% In that case, we'll take the first as our host, since proxies will append
%% additional values to the original.
host_from_host_values(HostValues) ->
    case HostValues of
        [] ->
            [];
        [H|_] ->
            case string:tokens(H, ",") of
                [FirstHost|_] ->
                    FirstHost;
                [] ->
                    H
            end
    end.

host_headers(Req) ->
    [ V || {V,_ReqState} <- [Req:get_header_value(H)
                             || H <- ["x-forwarded-host",
                                      "x-forwarded-server",
                                      "host"]],
           V /= undefined].

get_app_env(Key) ->
    application:get_env(webmachine, Key).

%% @private
%% @doc This function is used for cases where it may be desirable to
%% override the value that is set in the request metadata under the
%% `resource_module' key. An example would be a pattern where a set of
%% resource modules shares a lot of common functionality that is
%% contained in a single module and is used as the resource in all
%% dispatch rules and the `ModOpts' are used to specify a smaller
%% set of callbacks for resource specialization.
resource_module(Mod, ModOpts) ->
    resource_module(Mod, ModOpts, get_app_env(resource_module_option)).

resource_module(Mod, _, undefined) ->
    Mod;
resource_module(Mod, ModOpts, {ok, OptionVal}) ->
    proplists:get_value(OptionVal, ModOpts, Mod).

to_list(L) when is_list(L) ->
    L;
to_list(A) when is_atom(A) ->
    atom_to_list(A).

-ifdef(TEST).

host_from_host_values_test_() ->
    [
     {"when a host value is multi-part it resolves the first host correctly",
          ?_assertEqual("host1",
                       host_from_host_values(["host1,host2,host3:443","other", "other1"]))
     },
     {"when a host value is multi-part it retains the port",
          ?_assertEqual("host1:443",
                       host_from_host_values(["host1:443,host2","other", "other1"]))
     },
     {"a single host per header is resolved correctly",
          ?_assertEqual("host1:80",
                       host_from_host_values(["host1:80","other", "other1"]))
     },
     {"a missing host is resolved correctly",
          ?_assertEqual([],
                       host_from_host_values([]))
     }
    ].

    %[
     %{"when a host value is multi-part it resolves the first host correctly",
      %?_assertEqual("host1:443",
                    %host_from_host_values(["host1,host2,host3:443","other", "other1"])) }
    %].

-endif.


