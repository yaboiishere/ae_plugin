%% -*- mode:erlang; erlang-indent-level: 4; indent-tabs-mode: nil -*-

-module(ae_plugin_utils).

-compile(export_all).

-export([ start_aecore/0
        , load_aecore/0 ]).

-define(VERSION_FILE, <<"VERSION">>).
-define(REVISION_FILE, <<"REVISION">>).

start_aecore() ->
    case {os:getenv("AE_ROOT"), application:get_env(ae_plugin, node_root)} of
        {[_|_] = AERoot, _} ->
            start_aecore(AERoot);
        {false, {ok, <<NodeRoot_/binary>>}} ->
            NodeRoot = binary_to_list(NodeRoot_),
            ErlLib = filelib:wildcard(filename:join(NodeRoot, "lib/*/ebin")),
            ok     = code:add_pathsz(ErlLib),
            [SCfg] = filelib:wildcard(filename:join(NodeRoot, "releases/*/sys.config")),
            {ok, [AppEnvs]} = file:consult(SCfg),
            [[application:set_env(App, K, V) || {K, V} <- AppEnv] || {App, AppEnv} <- AppEnvs],
            start_aecore(NodeRoot);
        _ ->
            {error, {not_set, "AE_ROOT"}}
    end.
start_aecore(AERoot) ->
    application:set_env(mnesia, dir, filename:join(AERoot, "data/mnesia")),
    io:fwrite("Loading aecore and deps~n", []),
    load_aecore(),
    io:fwrite("Setting up data paths~n", []),
    fix_environment(AERoot),
    io:fwrite("Running setup hooks~n", []),
    setup:run_setup(),
    io:fwrite("Starting aecore~n", []),
    application:ensure_all_started(aecore).

fix_environment(AERoot) ->
    maybe_fix_setup_dirs(AERoot),
    fix_lager_paths(AERoot),
    ensure_version_files_linked(AERoot),
    ok.

maybe_fix_setup_dirs(AERoot) ->
    case application:get_env(setup, verify_directories) of
        {ok, true} ->
            %% Don't touch, don't reassign
            ok;
        _ ->
            [application:set_env(setup, Key, V)
             || {Key, V} <- [ {home, AERoot}
                            , {data_dir, filename:join(AERoot, "data")}
                            , {log_dir, filename:join(AERoot, "log")} ]],
            setup:verify_directories()
    end.

fix_lager_paths(AERoot) ->
    LagerEnv = application:get_all_env(lager),
    lists:foreach(
      fun({K, V}) ->
              maybe_fix_local_paths(lager, K, V, "log/", AERoot)
      end, LagerEnv).

maybe_fix_local_paths(App, K, V, Prefix, Root) ->
    F = fun(X) ->
                case string:prefix(X, Prefix) of
                    nomatch ->
                        X;
                    _Rest ->
                        filename:join(Root, X)
                end
        end,
    case xform(V, F) of
        V ->
            ok;
        NewV ->
            application:set_env(App, K, NewV)
    end.

xform(X, F) ->
    try F(X)
    catch
        error:_ ->
            xform_(X, F)
    end.

xform_([_|_] = List, F) ->
    [xform(E, F) || E <- List];
xform_(T, F) when is_tuple(T) ->
    list_to_tuple(xform(tuple_to_list(T), F));
xform_(X, _) ->
    X.

ensure_version_files_linked(AERoot) ->
    VersionFile = filename:join(AERoot, ?VERSION_FILE),
    file:make_symlink(VersionFile, ?VERSION_FILE),
    RevisionFile = filename:join(AERoot, ?REVISION_FILE),
    file:make_symlink(RevisionFile, ?REVISION_FILE).

load_aecore() ->
    {ok, []} = setup:reload_app(aecore),
    {ok, AecoreApps} = application:get_key(aecore, applications),
    ensure_loaded(AecoreApps).

ensure_loaded(Apps) ->
    Loaded = [A || {A,_,_} <- application:loaded_applications()],
    {ok, _NewLoaded} = ensure_loaded(Apps, Loaded).

ensure_loaded([A|As], Loaded) ->
    case lists:member(A, Loaded) of
        true ->
            ensure_loaded(As, Loaded);
        false ->
            %% {A, {ok, []}} = {A, setup:reload_app(A)},
            io:fwrite("Loading ~p~n", [A]),
            load_app(A),
            ensure_loaded(As, [A|Loaded])
    end;
ensure_loaded([], Loaded) ->
    {ok, Loaded}.

load_app(A) ->
    case application:load(A) of
        {error, {already_loaded, A}} ->
            ok;
        ok ->
            ok;
        Other ->
            error({Other, [load_app, A]})
    end.
