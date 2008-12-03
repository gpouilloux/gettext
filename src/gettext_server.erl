%%%-------------------------------------------------------------------
%%% File    : gettext_server.erl
%%% Created : 28 Oct 2003 by Torbjorn Tornkvist <tobbe@bluetail.com>
%%% @author Torbjorn Tornkvist <tobbe@bluetail.com>
%%% @doc Server for Erlang gettext.

-module(gettext_server).

-behaviour(gen_server).
%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% External exports
-export([start_link/0, start_link/1, start_link/2,
	 start/0, start/1, start/2]).

%% Standard callback functions to make this module work as an
%% initialization callback for itself.
-export([gettext_dir/0, gettext_def_lang/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
	 terminate/2, code_change/3]).

-include("gettext_internal.hrl").

-define(elog(X,Y), error_logger:info_msg("*elog ~p:~p: " X,
					[?MODULE, ?LINE | Y])).

-define(SERVER, ?MODULE).
-define(KEY(Lang,Key), {Key,Lang}).  % note reverse order
-define(ENTRY(Lang, Key, Val), {?KEY(Lang,Key), Val}).


-record(state, {
	  cbmod,             % callback module for initialization
	  cache = [],        % list_of( #cache{} )
          def_lang,          % default language
	  gettext_dir,       % Dir where all the data are stored
	  table_name         % autogenerated from server name
	 }).                 

%%%
%%% Hold info about the languages stored.
%%%
-record(cache, {
	  language  = ?DEFAULT_LANG,
	  charset   = ?DEFAULT_CHARSET
	 }).

%%====================================================================
%% External functions
%%====================================================================

%% Callback functions for default initialization.
gettext_dir() ->
    code:priv_dir(gettext).

gettext_def_lang() ->
    ?DEFAULT_LANG.
    

%%--------------------------------------------------------------------
%% Function: start_link/0
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    start_link(?MODULE).

start_link(CallBackMod) ->
    start_link(CallBackMod, ?SERVER).

start_link(CallBackMod, Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [CallBackMod, Name],[]).

%%--------------------------------------------------------------------

start() ->
    start(?MODULE).

start(CallBackMod) ->
    start(CallBackMod, ?SERVER).

start(CallBackMod, Name) ->
    gen_server:start({local, Name}, ?MODULE, [CallBackMod, Name], []).

%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%--------------------------------------------------------------------
init([CallBackMod0, Name]) ->
    CallBackMod = get_callback_mod(CallBackMod0),
    GettextDir = get_gettext_dir(CallBackMod),
    DefLang = get_default_lang(CallBackMod),
    TableNameStr = atom_to_list(Name) ++ "_db",
    TableName = list_to_atom(TableNameStr),
    Cache = create_db(TableName, GettextDir),
    {ok, #state{cache       = Cache, 
		cbmod       = CallBackMod,
		gettext_dir = GettextDir,
		def_lang    = DefLang,
		table_name  = TableName
               }}.

%%%
%%% The GETTEXT_CBMOD environment variable takes precedence!
%%%
get_callback_mod(CallBackMod0) ->
    case os:getenv(?ENV_CBMOD) of
	false -> CallBackMod0;
	CbMod -> list_to_atom(CbMod)
    end.

%%%
%%% The GETTEXT_DIR environment variable takes precedence!
%%% Next we will try to get hold of the value from the callback.
%%%
get_gettext_dir(CallBackMod) ->
    case os:getenv(?ENV_ROOT_DIR) of
	false -> 
	    case catch CallBackMod:gettext_dir() of
		Dir when is_list(Dir) -> Dir;
		_ -> gettext_dir() % fallback
	    end;
	Dir -> Dir
    end.

%%%
%%% The GETTEXT_DIR environment variable takes precedence!
%%% Next we will try to get hold of the value from the callback.
%%%
get_default_lang(CallBackMod) ->
    case os:getenv(?ENV_DEF_LANG) of
	false -> 
	    case catch CallBackMod:gettext_def_lang() of
		Dir when is_list(Dir) -> Dir;
		_ -> gettext_def_lang() % fallback
	    end;
	DefLang -> DefLang
    end.


%%--------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call({key2str, Key, Lang}, _From, State) ->
    TableName = State#state.table_name,
    Reply = lookup(TableName, Lang, Key),
    {reply, Reply, State};
%%
handle_call({lang2cset, Lang}, _From, State) ->
    Reply = case lists:keysearch(Lang, #cache.language, State#state.cache) of
		false      -> {error, "not found"};
		{value, C} -> {ok, C#cache.charset}
	    end,
    {reply, Reply, State};
%%
handle_call({store_pofile, Lang, File}, _From, State) ->
    GettextDir = State#state.gettext_dir,
    TableName  = State#state.table_name,
    case store_pofile(TableName, Lang, File, GettextDir, State#state.cache) of
	{ok, NewCache} ->
	    {reply, ok, State#state{cache = NewCache}};
	Else ->
	    {reply, Else, State}
    end;
%%
handle_call(all_lcs, _From, State) ->
    TableName = State#state.table_name,
    Reply = all_lcs_internal(TableName),
    {reply, Reply, State};
%%
handle_call({reload_custom_lang, Lang}, _From, State) ->
    GettextDir = State#state.gettext_dir,
    TableName  = State#state.table_name,
    case reload_custom_lang(TableName, GettextDir, Lang) of
	ok   -> {reply, ok, State};
	Else -> {reply, Else, State}
    end;
%%
handle_call({unload_custom_lang, Lang}, _From, State) ->
    GettextDir = State#state.gettext_dir,
    TableName  = State#state.table_name,
    {reply, unload_custom_lang(TableName, GettextDir, Lang), State};
%%
handle_call(recreate_db, _From, State) ->
    recreate_db(State#state.table_name, State#state.gettext_dir),
    {reply, ok, State};
%%
handle_call(gettext_dir, _From, State) ->
    {reply, State#state.gettext_dir, State};
%%
handle_call({change_gettext_dir, Dir}, _From, State) ->
    recreate_db(State#state.table_name, Dir),
    {reply, ok, State#state{gettext_dir = Dir}};
%%
handle_call(default_lang, _From, State) ->
    {reply, State#state.def_lang, State}.


%%--------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

db_filename(TableName, GettextDir) ->
    filename:join(GettextDir,  atom_to_list(TableName) ++ ".dets").

create_db(TableName, GettextDir) ->
    create_db(TableName, GettextDir, db_filename(TableName, GettextDir)).

create_db(TableName, GettextDir, Fname) ->
    filelib:ensure_dir(Fname), 
    init_db_table(TableName, GettextDir, Fname).

recreate_db(TableName, GettextDir) ->
    Fname = db_filename(TableName, GettextDir),
    dets:close(TableName),
    file:delete(Fname),
    create_db(TableName, GettextDir, Fname).

unload_custom_lang(TableName, GettextDir, Lang) ->
    Fname = filename:join([GettextDir, ?LANG_DIR, ?CUSTOM_DIR,
			   Lang, ?POFILE]),
    case filelib:is_file(Fname) of
	true ->
	    dets:match_delete(TableName, ?ENTRY(Lang,'_','_')),
            recreate_ets_table(TableName),
	    ok;
	false ->
	    {error, "no lang"}
    end.

reload_custom_lang(TableName, GettextDir, Lang) ->
    dets:match_delete(TableName, ?ENTRY(Lang,'_','_')),
    Dir = filename:join([GettextDir, ?LANG_DIR, ?CUSTOM_DIR, Lang]),
    Fname = filename:join([Dir, ?POFILE]), 
    insert_po_file(TableName, Lang, Fname),
    recreate_ets_table(TableName),
    ok.

store_pofile(TableName, Lang, File, GettextDir, Cache) ->
    Dir = filename:join([GettextDir, ?LANG_DIR, ?CUSTOM_DIR, Lang]),
    Fname = filename:join([Dir, ?POFILE]), 
    filelib:ensure_dir(Fname), 
    case file:write_file(Fname, File) of
	ok ->
	    case lists:keymember(Lang, #cache.language, Cache) of
		true  -> delete_lc(TableName, Lang);
		false -> false
	    end,
	    insert_po_file(TableName, Lang, Fname),
	    {ok, [set_charset(TableName, #cache{language = Lang}) | Cache]};
	_ ->
	    {error, "failed to write PO file to disk"}
    end.

set_charset(TableName, C) ->
    case lookup(TableName, C#cache.language, ?GETTEXT_HEADER_INFO) of
	?GETTEXT_HEADER_INFO ->                   % nothing found...
	    C#cache{charset = ?DEFAULT_CHARSET};  % fallback
	Pfinfo ->
	    CharSet = get_charset(Pfinfo),
	    C#cache{charset = CharSet}
    end.


get_charset(Pfinfo) ->
    g_charset(string:tokens(Pfinfo,[$\n])).

g_charset(["Content-Type:" ++ Rest|_]) -> g_cset(Rest);
g_charset([_H|T])                      -> g_charset(T);
g_charset([])                          -> ?DEFAULT_CHARSET.

g_cset("charset=" ++ Charset) -> rm_trailing_stuff(Charset);
g_cset([_|T])                 -> g_cset(T);
g_cset([])                    -> ?DEFAULT_CHARSET.

rm_trailing_stuff(Charset) ->
    lists:reverse(eat_dust(lists:reverse(Charset))).

eat_dust([$\s|T]) -> eat_dust(T);
eat_dust([$\n|T]) -> eat_dust(T);
eat_dust([$\r|T]) -> eat_dust(T);
eat_dust([$\t|T]) -> eat_dust(T);
eat_dust(T)       -> T.


init_db_table(TableName, GettextDir, TableFile) ->
    case filelib:is_regular(TableFile) of
	false ->
	    create_and_populate(TableName, GettextDir, TableFile);
	true ->
	    %% If the dets file is broken, dets may not be able to repair it 
	    %% itself (it may be only half-written). So check and recreate 
	    %% if needed instead.
	    case open_dets_file(TableName, TableFile) of
		ok -> create_cache(TableName);
		_  -> create_and_populate(TableName, GettextDir, TableFile)
	    end
    end.

create_cache(TableName) ->
    F = fun(LC, Acc) ->
		case lookup(TableName, LC, ?GETTEXT_HEADER_INFO) of
		    ?GETTEXT_HEADER_INFO ->
			%% nothing found...
			?elog("Could not find header info for lang: ~s~n",[LC]),
			Acc;
		    Pfinfo ->
			CS = get_charset(Pfinfo),
			[#cache{language = LC, charset = CS}|Acc]
		end
	end,
    recreate_ets_table(TableName),
    lists:foldl(F, [], all_lcs_internal(TableName)).

create_and_populate(TableName, GettextDir, TableFile) ->
    ?elog("TableFile = ~p~n", [TableFile]),
    %% Need to create and populate the DB.
    {ok, _} = dets:open_file(TableName,
			     [{file, TableFile},
			      %% creating on disk, esp w auto_save,
			      %% takes "forever" on flash disk
			      {ram_file, true}]), 
    L = populate_db(TableName, GettextDir),
    dets:close(TableName),    % flush to disk
    {ok, _} = dets:open_file(TableName, [{file, TableFile}]),
    recreate_ets_table(TableName),
    L.

recreate_ets_table(TableName) ->
    try ets:delete(get(ets_table))
    catch _:_ -> true
    after
        create_and_populate_ets_table(TableName)
    end.

%% To speed up the read access 10-100 times !!
create_and_populate_ets_table(TableName) ->
    try 
        E = ets:new(?MODULE, [set, private]),
	put(ets_table, E),
        ets:from_dets(E, TableName),
        true
    catch 
            _:_ -> false
    end.
            
        

open_dets_file(Tname, Fname) ->
    Opts = [{file, Fname}, {repair, false}],
    case dets:open_file(Tname, Opts) of
	{ok, _} ->
	    ok;
	_ ->
	    file:delete(Fname),
	    error
    end.

%%%
%%% Insert the given languages into the DB.
%%%
%%% NB: It is important to insert the 'predefined' language
%%%     definitions first since a custom language should be
%%%     able to 'shadow' the the same predefined language.
%%%
populate_db(TableName, GettextDir) ->
    L = insert_predefined(TableName, GettextDir, []), 
    insert_custom(TableName, GettextDir, L).

insert_predefined(TableName, GettextDir, L) ->
    Dir = filename:join([GettextDir, ?LANG_DIR, ?DEFAULT_DIR]),
    insert_data(TableName, Dir, L).

insert_data(TableName, Dir, L) ->
    case file:list_dir(Dir) of
	{ok, Dirs} ->
	    %% TODO: this should accept only *.po-files, not just filter some
	    F = fun([$.|_], Acc)     -> Acc;  % ignore in a local inst. env.
		   ("CVS" ++ _, Acc) -> Acc;  % ignore in a local inst. env.
		   (LC, Acc)         ->
			Fname = filename:join([Dir, LC, ?POFILE]),
			insert_po_file(TableName, LC, Fname),
			[#cache{language = LC} | Acc]
		end,
	    lists:foldl(F, L, Dirs);
	_ ->
	    L
    end.

insert_po_file(TableName, LC, Fname) ->
    case file:read_file_info(Fname) of
	{ok, _} ->
	    insert(TableName, LC, gettext:parse_po(Fname));
	_ ->
	    ?elog("gettext_server: Could not read ~s~n", [Fname]),
	    {error, "could not read PO file"}
    end.

insert_custom(TableName, GettextDir, L) ->
    Dir = filename:join([GettextDir, ?LANG_DIR, ?CUSTOM_DIR]),
    insert_data(TableName, Dir, L).

insert(TableName, LC, L) ->
    F = fun({Key, Val}) ->
		dets:insert(TableName, ?ENTRY(LC, Key, Val))
	end,
    lists:foreach(F, L).

lookup(TableName, Lang, Key) ->
    try ets:lookup(get(ets_table), ?KEY(Lang, Key)) of
	[]          -> Key;  
	[?ENTRY(_,_,Str)|_] -> Str
    catch
        _:_ ->
	    case dets:lookup(TableName, ?KEY(Lang, Key)) of
		[]          -> Key;  
		[?ENTRY(_,_,Str)|_] -> Str
	    end
    end.
    

delete_lc(TableName, LC) ->
    dets:match_delete(TableName, ?ENTRY(LC, '_', '_')).
    

all_lcs_internal(TableName) ->
    L = dets:match(TableName, ?ENTRY('$1', ?GETTEXT_HEADER_INFO, '_')),
    [hd(X) || X <- L].
