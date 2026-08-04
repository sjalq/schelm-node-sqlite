effect module Schelm.Node.Sqlite.Manager where { command = MyCmd } exposing (Operation, cancel, submit)

import Dict exposing (Dict)
import Json.Encode as Encode
import Platform
import Platform.Cmd exposing (Cmd)
import Process
import Schelm.Node.Sqlite.Internal.Runtime as Runtime
import Task exposing (Task)


type Operation = Operation Int

type MyCmd msg = Submit String Encode.Value (Operation -> Int -> Runtime.Handle -> Task Never msg) (Operation -> msg) | Cancel Operation

type alias Job msg = { operation : Operation, run : Int -> Runtime.Handle -> Task Never msg }
type Database msg = Starting Encode.Value (List (Job msg)) | Ready Runtime.Handle Int (Maybe Active) (List (Job msg))
type alias Active = { operation : Operation, pid : Process.Id }
type alias State msg = { nextOperation : Int, databases : Dict String (Database msg), owners : Dict Int String, queued : Int }
type SelfMsg msg = Opened String Runtime.Handle | OpenFailed String | Completed String Int Int msg

type alias MyRouter msg = Platform.Router msg (SelfMsg msg)

submit key options onStarted run = command (Submit key options run onStarted)
cancel operation = command (Cancel operation)
cmdMap fn cmd = case cmd of
    Submit key options run started -> Submit key options (\op rid handle -> run op rid handle |> Task.map fn) (started >> fn)
    Cancel op -> Cancel op

init = Task.succeed { nextOperation = 1, databases = Dict.empty, owners = Dict.empty, queued = 0 }

onEffects router commands state = applyCommands router commands state
applyCommands router commands state = case commands of
    [] -> Task.succeed state
    first :: rest -> applyCommand router first state |> Task.andThen (applyCommands router rest)

applyCommand router cmd state = case cmd of
    Cancel (Operation operationId) -> cancelOwned operationId state
    Submit key options run started ->
        if state.queued >= 1024 then Platform.sendToApp router (started (Operation 0)) |> Task.andThen (\_ -> Task.succeed state)
        else
            let op = Operation state.nextOperation
                job = { operation = op, run = run op }
                next = { state | nextOperation = increment state.nextOperation, owners = Dict.insert state.nextOperation key state.owners, queued = state.queued + 1 }
            in Platform.sendToApp router (started op) |> Task.andThen (\_ -> admit router key options job next)

admit router key options job state = case Dict.get key state.databases of
    Just (Starting existing queue) -> Task.succeed { state | databases = Dict.insert key (Starting existing (boundedEnqueue job queue)) state.databases }
    Just (Ready handle rid Nothing queue) -> dispatch router key handle rid job { state | databases = Dict.insert key (Ready handle rid Nothing queue) state.databases }
    Just (Ready handle rid active queue) -> Task.succeed { state | databases = Dict.insert key (Ready handle rid active (boundedEnqueue job queue)) state.databases }
    Nothing ->
        if Dict.size state.databases >= 8 then Task.succeed (rejectJob job state)
        else
            let open = Runtime.start options |> Task.andThen (Opened key >> Platform.sendToSelf router) |> Task.onError (\_ -> Platform.sendToSelf router (OpenFailed key))
            in Process.spawn open |> Task.map (\_ -> { state | databases = Dict.insert key (Starting options [ job ]) state.databases })

boundedEnqueue job queue = if List.length queue >= 256 then queue else queue ++ [ job ]
rejectJob job state = let (Operation n) = job.operation in { state | owners = Dict.remove n state.owners, queued = max 0 (state.queued - 1) }

dispatch router key handle rid job state =
    let (Operation operationId) = job.operation
        completion = job.run rid handle |> Task.andThen (\msg -> Platform.sendToSelf router (Completed key operationId rid msg))
    in Process.spawn completion |> Task.map (\pid -> { state | databases = Dict.insert key (Ready handle (rid + 1002) (Just { operation = job.operation, pid = pid }) []) state.databases })

onSelfMsg router self state = case self of
    OpenFailed key -> Task.succeed { state | databases = Dict.remove key state.databases }
    Opened key handle -> case Dict.get key state.databases of
        Just (Starting _ (job :: rest)) -> dispatch router key handle 2 job { state | databases = Dict.insert key (Ready handle 2 Nothing rest) state.databases }
        _ -> Runtime.close handle |> Task.andThen (\_ -> Task.succeed state)
    Completed key operationId rid message ->
        case Dict.get key state.databases of
            Just (Ready handle next (Just active) queue) ->
                let (Operation activeId) = active.operation in
                if activeId /= operationId then Task.succeed state
                else
                    let settled = { state | owners = Dict.remove operationId state.owners, queued = max 0 (state.queued - 1), databases = Dict.insert key (Ready handle next Nothing queue) state.databases }
                    in Platform.sendToApp router message |> Task.andThen (\_ -> case queue of
                        [] -> Task.succeed settled
                        first :: rest -> dispatch router key handle next first { settled | databases = Dict.insert key (Ready handle next Nothing rest) settled.databases })
            _ -> Task.succeed state

cancelOwned operationId state = case Dict.get operationId state.owners of
    Nothing -> Task.succeed state
    Just key -> case Dict.get key state.databases of
        Just (Ready handle rid (Just active) queue) -> let (Operation activeId) = active.operation in if activeId == operationId then Process.kill active.pid |> Task.map (\_ -> { state | databases = Dict.remove key state.databases, owners = Dict.remove operationId state.owners, queued = max 0 (state.queued - 1) }) else Task.succeed (removeQueued key operationId state)
        _ -> Task.succeed (removeQueued key operationId state)
removeQueued key operationId state = case Dict.get key state.databases of
    Just (Starting options queue) -> { state | databases = Dict.insert key (Starting options (without operationId queue)) state.databases, owners = Dict.remove operationId state.owners, queued = max 0 (state.queued - 1) }
    Just (Ready handle rid active queue) -> { state | databases = Dict.insert key (Ready handle rid active (without operationId queue)) state.databases, owners = Dict.remove operationId state.owners, queued = max 0 (state.queued - 1) }
    Nothing -> state
without target = List.filter (\job -> let (Operation n) = job.operation in n /= target)
increment n = if n >= 9007199254740990 then 1 else n + 1
