%% 多进程编译,修改自chenglitao的mmake.erl
%% 解析Emakefile,根据获取{mods, options}列表,
%% 按照次序编译每项(解决编译顺序的问题)
%% 其中mods也可以包含多个模块,当大于1个时,
%% 可以启动多个process进行编译,从而提高编译速度.

%% smart_make
%% 优化1: 提前为worker分配任务 改为 即时分配，按需分配 任务。
%% 优化2: 支持分布式编译
%% 优化3: 为了尽可能地让工作进程同时结束，将大模块放在前面编译，小模块放在最后面编译(依据filelib:file_size/1)


-module(smake).
-export([all/0, all/1, all/2, files/2, files/3]).
-compile(export_all).
-include_lib("kernel/include/file.hrl").

-author("shoumuyushan@gmail.com").

-define(MakeOpts,[noexec,load,netload,noload]).

all() ->
	Worker = erlang:system_info(schedulers),
	all(Worker).

all(Worker) when is_integer(Worker) ->
    all(Worker, []);
all(Options) when is_list(Options) ->
	Worker = erlang:system_info(schedulers),
	all(Worker, Options).
	
nowsec() ->
	{M, S, _} = erlang:now(),
	M * 1000000 + S.
	
all(Worker, Options) when is_integer(Worker) ->
	%% 记录开始编译时间
	put(start_sec, nowsec()),
	%% 加入分布式编译集群
	case option(compile_server, Options) of
		false ->
			ignore;
		CompileNodeName ->
			case net_adm:ping(CompileNodeName) of
				pong ->
					OtherNodes = rpc:call(CompileNodeName, erlang, nodes, []),
					lists:foreach(fun(Node) -> net_adm:ping(Node) end, OtherNodes);
				pang ->
					io:format("connect to compile server .............[FAIL]\n")
			end
	end,
    {MakeOpts, CompileOpts} = sort_options(Options,[],[]),
    case read_emakefile('Emakefile', CompileOpts) of
        Files when is_list(Files) ->
            do_make_files(Worker, Files, MakeOpts);
        error ->
            error
    end.

files(Worker, Fs) ->
    files(Worker, Fs, []).

files(Worker, Fs0, Options) ->
    Fs = [filename:rootname(F,".erl") || F <- Fs0],
    {MakeOpts,CompileOpts} = sort_options(Options,[],[]),
    case get_opts_from_emakefile(Fs,'Emakefile',CompileOpts) of
	Files when is_list(Files) ->
	    do_make_files(Worker, Files,MakeOpts);	   
	error -> error
    end.

do_make_files(Worker, Fs, Opts) ->
    %%io:format("worker:~p~nfs:~p~nopts:~p~n", [Worker, Fs, Opts]),
    process(Fs, Worker, lists:member(noexec, Opts), load_opt(Opts)).

sort_options([H|T],Make,Comp) ->
    case lists:member(H,?MakeOpts) of
	true ->
	    sort_options(T,[H|Make],Comp);
	false ->
	    sort_options(T,Make,[H|Comp])
    end;
sort_options([],Make,Comp) ->
    {Make,lists:reverse(Comp)}.

%%% Reads the given Emakefile and returns a list of tuples: {Mods,Opts}
%%% Mods is a list of module names (strings)
%%% Opts is a list of options to be used when compiling Mods
%%%
%%% Emakefile can contain elements like this:
%%% Mod.
%%% {Mod,Opts}.
%%% Mod is a module name which might include '*' as wildcard
%%% or a list of such module names
%%%
%%% These elements are converted to [{ModList,OptList},...]
%%% ModList is a list of modulenames (strings)
read_emakefile(Emakefile,Opts) ->
    case file:consult(Emakefile) of
	{ok, Emake} ->
	    transform(Emake,Opts,[],[]);
	{error,enoent} ->
	    %% No Emakefile found - return all modules in current 
	    %% directory and the options given at command line
	    Mods = [filename:rootname(F) ||  F <- filelib:wildcard("*.erl")],
	    [{Mods, Opts}];
	{error,Other} ->
	    io:format("make: Trouble reading 'Emakefile':~n~p~n",[Other]),
	    error
    end.

transform([{Mod,ModOpts}|Emake],Opts,Files,Already) ->
    case expand(Mod,Already) of
	[] -> 
	    transform(Emake,Opts,Files,Already);
	Mods -> 
	    transform(Emake,Opts,[{Mods,ModOpts++Opts}|Files],Mods++Already)
    end;
transform([Mod|Emake],Opts,Files,Already) ->
    case expand(Mod,Already) of
	[] -> 
	    transform(Emake,Opts,Files,Already);
	Mods ->
	    transform(Emake,Opts,[{Mods,Opts}|Files],Mods++Already)
    end;
transform([],_Opts,Files,_Already) ->
    lists:reverse(Files).

expand(Mod,Already) when is_atom(Mod) ->
    expand(atom_to_list(Mod),Already);
expand(Mods,Already) when is_list(Mods), not is_integer(hd(Mods)) ->
    lists:concat([expand(Mod,Already) || Mod <- Mods]);
expand(Mod,Already) ->
    case lists:member($*,Mod) of
	true -> 
	    Fun = fun(F,Acc) -> 
			  M = filename:rootname(F),
			  case lists:member(M,Already) of
			      true -> Acc;
			      false -> [M|Acc]
			  end
		  end,
	    lists:foldl(Fun, [], filelib:wildcard(Mod++".erl"));
	false ->
	    Mod2 = filename:rootname(Mod, ".erl"),
	    case lists:member(Mod2,Already) of
		true -> [];
		false -> [Mod2]
	    end
    end.

%%% Reads the given Emakefile to see if there are any specific compile 
%%% options given for the modules.
get_opts_from_emakefile(Mods,Emakefile,Opts) ->
    case file:consult(Emakefile) of
	{ok,Emake} ->
	    Modsandopts = transform(Emake,Opts,[],[]),
	    ModStrings = [coerce_2_list(M) || M <- Mods],
	    get_opts_from_emakefile2(Modsandopts,ModStrings,Opts,[]); 
	{error,enoent} ->
	    [{Mods, Opts}];
	{error,Other} ->
	    io:format("make: Trouble reading 'Emakefile':~n~p~n",[Other]),
	    error
    end.

get_opts_from_emakefile2([{MakefileMods,O}|Rest],Mods,Opts,Result) ->
    case members(Mods,MakefileMods,[],Mods) of
	{[],_} -> 
	    get_opts_from_emakefile2(Rest,Mods,Opts,Result);
	{I,RestOfMods} ->
	    get_opts_from_emakefile2(Rest,RestOfMods,Opts,[{I,O}|Result])
    end;
get_opts_from_emakefile2([],[],_Opts,Result) ->
    Result;
get_opts_from_emakefile2([],RestOfMods,Opts,Result) ->
    [{RestOfMods,Opts}|Result].
    
members([H|T],MakefileMods,I,Rest) ->
    case lists:member(H,MakefileMods) of
	true ->
	    members(T,MakefileMods,[H|I],lists:delete(H,Rest));
	false ->
	    members(T,MakefileMods,I,Rest)
    end;
members([],_MakefileMods,I,Rest) ->
    {I,Rest}.


%% Any flags that are not recognixed as make flags are passed directly
%% to the compiler.
%% So for example make:all([load,debug_info]) will make everything
%% with the debug_info flag and load it.
load_opt(Opts) ->
    case lists:member(netload,Opts) of
	true -> 
	    netload;
	false ->
	    case lists:member(load,Opts) of
		true ->
		    load;
		_ ->
		    noload
	    end
    end.

%% 处理
process([{[], _Opts}|Rest], Worker, NoExec, Load) ->
    process(Rest, Worker, NoExec, Load);
process([{L, Opts}|Rest], Worker, NoExec, Load) ->
    Len = length(L),
    Worker2 = erlang:min(Len, Worker),
    case catch do_worker(L, Opts, NoExec, Load, Worker2) of
        error ->
            error;
        ok ->
            process(Rest, Worker, NoExec, Load)
    end;
process([], _Worker, _NoExec, _Load) ->
	EndSec = nowsec(),
	StartSec = get(start_sec),
	io:format("Compile Time Consume ~w second",[EndSec-StartSec]),
    up_to_date.

%% 将文件从大到小排列
sort_file(FileList) ->
	FileInfoList = [{filelib:file_size(File++".erl"), File} || File <- FileList],
	lists:reverse([A || {_,A} <-lists:sort(FileInfoList) ]).
	
%% worker进行编译,
do_worker(L, Opts, NoExec, Load, Worker) ->
	{_, Ref} = erlang:spawn_monitor(fun() -> 
											MasterPid = self(),											
											lists:foreach(fun(_E) ->
																  spawn_monitor(fun() ->worker_loop([], Opts, NoExec, Load, MasterPid) end) 
														  end, lists:seq(1, Worker)),
											case nodes() of
												[] ->
													ignore;
												NodeList ->
													io:format("nodeList:~p\n",[NodeList]),
													lists:foreach(fun(Node) ->
																		%% 远程节点核心数-1个工作进程
																		ValidCpuNum = rpc:call(Node, erlang, system_info, [schedulers]),
																		lists:foreach(fun(_) ->
																		  spawn_monitor(fun() ->remote_worker(Node,[], Opts, NoExec, Load, MasterPid) end)
																		  end, lists:seq(1,ValidCpuNum-1))
																  end, NodeList)
											end,
											master_loop(sort_file(L), length(L))
									end), 
	receive 
		{'DOWN', Ref, process, _, Reason} ->	
			if Reason =:= normal ->
				   ok;
			   true ->
				   error
			end
	end.

%% UnfinishedTaskNum用来确保所有编译文件都完成
master_loop([], 0) ->
	ok;
master_loop(L,UnfinishedTaskNum) ->
	receive 
		{WorkerPid, get_task} ->
			case L of
				[File|Rest] ->
					WorkerPid ! {task, [File]},
					master_loop(Rest,UnfinishedTaskNum);
				[] ->
					WorkerPid ! son_you_can_stop,
					master_loop([], UnfinishedTaskNum)
			end;
		{finished_task, Files} ->
			master_loop(L, UnfinishedTaskNum - length(Files));
		{'DOWN', _, process, _, normal} ->
			master_loop(L,UnfinishedTaskNum);
		{'DOWN', _, process, _, {i_quit, Job}} ->
			master_loop(Job++L,UnfinishedTaskNum- length(Job));
		{'DOWN', _, process, _, Reason} ->
			erlang:exit(Reason)
	end.
	
%% 远程编译worker
remote_worker( Node,[], Opts, NoExec, Load, MasterPid) ->
	MasterPid ! {self(), get_task},
	%% 判断Master是否已停止
	case erlang:is_process_alive(MasterPid) of
		true ->
			receive 
				{task, Files} ->
					remote_worker( Node,Files, Opts, NoExec, Load, MasterPid);
				%% 没有任务可以接了
				son_you_can_stop ->
					father_told_me_stop_so_i_do
			end;
		false ->
			finished
	end;
remote_worker( Node,[F|Rest]=Job, Opts, NoExec, Load, MasterPid) ->
	case remote_compile( Node, F, NoExec, Load, Opts) of
		error ->
			exit({i_quit, Job});
		_ ->
			MasterPid ! {finished_task, [F]},
			ok
	end,
	remote_worker( Node,Rest, Opts, NoExec, Load, MasterPid).

remote_compile( Node, F, NoExec, Load, Opts) ->
	recompilep(coerce_2_list(F), NoExec, Load, [{remote_compile,Node}|Opts]).
			
%% 本地编译worker
worker_loop([], Opts, NoExec, Load, MasterPid) ->
	MasterPid ! {self(), get_task},
	%% 判断Master是否已停止
	case erlang:is_process_alive(MasterPid) of
		true ->
			receive 
				{task, Files} ->
					worker_loop(Files, Opts, NoExec, Load, MasterPid);
				%% 没有任务可以接了
				son_you_can_stop ->
					father_told_me_stop_so_i_do
			end;
		false ->
			finished
	end;
worker_loop([F|Rest]=Job, Opts, NoExec, Load, MasterPid) ->
	case recompilep(coerce_2_list(F), NoExec, Load, Opts) of
		error ->
			exit({i_quit, Job});
		_ ->
			MasterPid ! {finished_task, [F]},
			ok
	end,
	worker_loop(Rest, Opts, NoExec, Load, MasterPid).
			

recompilep(File, NoExec, Load, Opts) ->
    ObjName = lists:append(filename:basename(File),
			   code:objfile_extension()),
    ObjFile = case lists:keysearch(outdir,1,Opts) of
		  {value,{outdir,OutDir}} ->
		      filename:join(coerce_2_list(OutDir),ObjName);
		  false ->
		      ObjName
	      end,
    case exists(ObjFile) of
	true ->
	    recompilep1(File, NoExec, Load, Opts, ObjFile);
	false ->
	    recompile(File, NoExec, Load, Opts)
    end.
 
recompilep1(File, NoExec, Load, Opts, ObjFile) ->
    {ok, Erl} = file:read_file_info(lists:append(File, ".erl")),
    {ok, Obj} = file:read_file_info(ObjFile),
	 recompilep1(Erl, Obj, File, NoExec, Load, Opts).

recompilep1(#file_info{mtime=Te},
	    #file_info{mtime=To}, File, NoExec, Load, Opts) when Te>To ->
    recompile(File, NoExec, Load, Opts);
recompilep1(_Erl, #file_info{mtime=To}, File, NoExec, Load, Opts) ->
    recompile2(To, File, NoExec, Load, Opts).

%% recompile2(ObjMTime, File, NoExec, Load, Opts)
%% Check if file is of a later date than include files.
recompile2(ObjMTime, File, NoExec, Load, Opts) ->
    IncludePath = include_opt(Opts),
    case check_includes(lists:append(File, ".erl"), IncludePath, ObjMTime) of
	true ->
	    recompile(File, NoExec, Load, Opts);
	false ->
	    false
    end.

include_opt([{i,Path}|Rest]) ->
    [Path|include_opt(Rest)];
include_opt([_First|Rest]) ->
    include_opt(Rest);
include_opt([]) ->
    [].

%% recompile(File, NoExec, Load, Opts)
%% Actually recompile and load the file, depending on the flags.
%% Where load can be netload | load | noload

recompile(File, true, _Load, _Opts) ->
    io:format("Out of date: ~s\n",[File]);
recompile(File, false, noload, Opts) ->
	recompile2(File, Opts);
recompile(File, false, load, Opts) ->
	recompile2(File, Opts);
recompile(File, false, netload, Opts) ->
    io:format("Recompile: ~s\n",[File]),
	recompile2(File, Opts).

recompile2(File, [{remote_compile, Node} | Opts]) ->
    io:format("remote Recompile in ~p: ~s\n",[Node, File]),
	case catch rpc:call(Node, compile2, file, [File, [report_errors, report_warnings, error_summary |Opts]]) of
		{'EXIT', _}=Reason  ->
			io:format("~100000p",[Reason]),
			error;
		Result ->
			Result
	end;
recompile2(File, Opts) ->
    io:format("local Recompile: ~s\n",[File]),
	compile:file(File, [report_errors, report_warnings, error_summary |Opts]).

exists(File) ->
    case file:read_file_info(File) of
	{ok, _} ->
	    true;
	_ ->
	    false
    end.

coerce_2_list(X) when is_atom(X) ->
    atom_to_list(X);
coerce_2_list(X) ->
    X.

%%% If you an include file is found with a modification
%%% time larger than the modification time of the object
%%% file, return true. Otherwise return false.
check_includes(File, IncludePath, ObjMTime) ->
    Path = [filename:dirname(File)|IncludePath], 
    case epp:open(File, Path, []) of
	{ok, Epp} ->
	    check_includes2(Epp, File, ObjMTime);
	_Error ->
	    false
    end.
    
check_includes2(Epp, File, ObjMTime) ->
    case epp:parse_erl_form(Epp) of
	{ok, {attribute, 1, file, {File, 1}}} ->
	    check_includes2(Epp, File, ObjMTime);
	{ok, {attribute, 1, file, {IncFile, 1}}} ->
	    case file:read_file_info(IncFile) of
		{ok, #file_info{mtime=MTime}} when MTime>ObjMTime ->
		    epp:close(Epp),
		    true;
		_ ->
		    check_includes2(Epp, File, ObjMTime)
	    end;
	{ok, _} ->
	    check_includes2(Epp, File, ObjMTime);
	{eof, _} ->
	    epp:close(Epp),
	    false;
	{error, _Error} ->
	    check_includes2(Epp, File, ObjMTime)
    end.


outdir(Options) ->
	case option(outdir, Options) of
		false ->
			c:pwd();
		Dir ->
			Dir
	end.
			
	
option(OptionType, Options) ->
	case lists:keyfind(OptionType, 1, Options) of
		{_, Value} ->
			Value;
		false ->
			false
	end.
		