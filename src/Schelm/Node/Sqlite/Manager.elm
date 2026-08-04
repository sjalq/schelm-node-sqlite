effect module Schelm.Node.Sqlite.Manager where { command = MyCmd } exposing (Operation, cancel, submit)

import Dict exposing (Dict)
import Json.Encode as Encode
import Platform
import Process
import Set exposing (Set)
import Schelm.Node.Sqlite.Internal.Runtime as Runtime
import Task exposing (Task)


type Operation
    = Operation Int


type MyCmd msg
    = Submit String Encode.Value (Operation -> Int -> Runtime.Handle -> Task Never msg) (Operation -> msg) (Operation -> msg) (Operation -> msg) (Operation -> msg)
    | Cancel Operation


type alias Queue a =
    { front : List a, back : List a, size : Int }


type alias Job msg =
    { operation : Operation
    , run : Int -> Runtime.Handle -> Task Never msg
    , rejected : msg
    , cancelled : msg
    , interrupted : msg
    }


type Database msg
    = Pending Encode.Value (Queue (Job msg))
    | Starting Encode.Value (Queue (Job msg))
    | Ready Encode.Value Runtime.Handle Int (Maybe (Active msg)) (Queue (Job msg))


type alias Active msg =
    { job : Job msg, pid : Process.Id }


type alias State msg =
    { nextOperation : Int
    , databases : Dict String (Database msg)
    , owners : Dict Int String
    , queued : Int
    , ready : Queue String
    , readySet : Set String
    }


type SelfMsg msg
    = Opened String Runtime.Handle
    | OpenFailed String
    | Completed String Int Int msg


type alias MyRouter msg =
    Platform.Router msg (SelfMsg msg)


submit key options onStarted onRejected onCancelled onInterrupted run =
    command (Submit key options run onStarted onRejected onCancelled onInterrupted)


cancel operation =
    command (Cancel operation)


cmdMap fn cmd =
    case cmd of
        Submit key options run started rejected cancelled interrupted ->
            Submit key options (\op rid handle -> run op rid handle |> Task.map fn) (started >> fn) (rejected >> fn) (cancelled >> fn) (interrupted >> fn)

        Cancel op ->
            Cancel op


init =
    Task.succeed { nextOperation = 1, databases = Dict.empty, owners = Dict.empty, queued = 0, ready = empty, readySet = Set.empty }


onEffects router commands state =
    applyCommands router commands state


applyCommands router commands state =
    case commands of
        [] ->
            schedule router state

        first :: rest ->
            applyCommand router first state |> Task.andThen (applyCommands router rest)


applyCommand router cmd state =
    case cmd of
        Cancel (Operation operationId) ->
            cancelOwned router operationId state

        Submit key options run started rejected cancelled interrupted ->
            let
                op =
                    Operation state.nextOperation

                job =
                    { operation = op
                    , run = run op
                    , rejected = rejected op
                    , cancelled = cancelled op
                    , interrupted = interrupted op
                    }
            in
            Platform.sendToApp router (started op)
                |> Task.andThen
                    (\_ ->
                        if state.queued >= 1024 || databaseQueueSize key state >= 256 then
                            Platform.sendToApp router job.rejected |> Task.andThen (\_ -> Task.succeed state)

                        else
                            admit router key options job
                                { state
                                    | nextOperation = increment state.nextOperation
                                    , owners = Dict.insert state.nextOperation key state.owners
                                    , queued = state.queued + 1
                                }
                    )


admit router key options job state =
    case Dict.get key state.databases of
        Just (Pending existing queue) ->
            Task.succeed { state | databases = Dict.insert key (Pending existing (enqueue job queue)) state.databases }

        Just (Starting existing queue) ->
            Task.succeed { state | databases = Dict.insert key (Starting existing (enqueue job queue)) state.databases }

        Just (Ready existing handle rid Nothing queue) ->
            Task.succeed
                (addReady key { state | databases = Dict.insert key (Ready existing handle rid Nothing (enqueue job queue)) state.databases })

        Just (Ready existing handle rid (Just active) queue) ->
            Task.succeed { state | databases = Dict.insert key (Ready existing handle rid (Just active) (enqueue job queue)) state.databases }

        Nothing ->
            if workerCount state >= 8 then
                Task.succeed { state | databases = Dict.insert key (Pending options (singleton job)) state.databases }

            else
                startDatabase router key options (singleton job) state


startDatabase router key options queue state =
    let
        open =
            Runtime.start options
                |> Task.andThen (Opened key >> Platform.sendToSelf router)
                |> Task.onError (\_ -> Platform.sendToSelf router (OpenFailed key))
    in
    Process.spawn open
        |> Task.map (\_ -> { state | databases = Dict.insert key (Starting options queue) state.databases })


schedule router state =
    case dequeue state.ready of
        Nothing ->
            rotateIdle router state

        Just ( key, rest ) ->
            case Dict.get key state.databases of
                Just (Ready options handle rid Nothing queue) ->
                    case dequeue queue of
                        Nothing ->
                            schedule router { state | ready = rest, readySet = Set.remove key state.readySet }

                        Just ( job, remaining ) ->
                            dispatch router key options handle rid job
                                { state
                                    | ready = rest
                                    , readySet = Set.remove key state.readySet
                                    , databases = Dict.insert key (Ready options handle rid Nothing remaining) state.databases
                                }
                                |> Task.andThen (schedule router)

                _ ->
                    schedule router { state | ready = rest }


dispatch router key options handle rid job state =
    let
        (Operation operationId) =
            job.operation

        completion =
            job.run rid handle |> Task.andThen (\msg -> Platform.sendToSelf router (Completed key operationId rid msg))
    in
    Process.spawn completion
        |> Task.map
            (\pid ->
                { state
                    | databases = Dict.insert key (Ready options handle (rid + 1) (Just { job = job, pid = pid }) (readyQueue state key)) state.databases
                }
            )


onSelfMsg router self state =
    case self of
        OpenFailed key ->
            case Dict.get key state.databases of
                Just (Starting _ queue) ->
                    settleQueue router queue { state | databases = Dict.remove key state.databases }

                _ ->
                    Task.succeed state

        Opened key handle ->
            case Dict.get key state.databases of
                Just (Starting options queue) ->
                    schedule router (addReady key { state | databases = Dict.insert key (Ready options handle 2 Nothing queue) state.databases })

                _ ->
                    Runtime.close handle |> Task.andThen (\_ -> Task.succeed state)

        Completed key operationId _ message ->
            case Dict.get key state.databases of
                Just (Ready options handle next (Just active) queue) ->
                    let
                        (Operation activeId) =
                            active.job.operation
                    in
                    if activeId /= operationId then
                        Task.succeed state

                    else
                        let
                            settled =
                                forget active.job.operation
                                    { state | databases = Dict.insert key (Ready options handle next Nothing queue) state.databases }
                        in
                        Platform.sendToApp router message
                            |> Task.andThen (\_ -> schedule router (addReady key settled))

                _ ->
                    Task.succeed state


cancelOwned router operationId state =
    case Dict.get operationId state.owners of
        Nothing ->
            Task.succeed state

        Just key ->
            case Dict.get key state.databases of
                Just (Ready options _ _ (Just active) queue) ->
                    let
                        (Operation activeId) =
                            active.job.operation
                    in
                    if activeId == operationId then
                        Process.kill active.pid
                            |> Task.andThen (\_ -> Platform.sendToApp router active.job.interrupted)
                            |> Task.andThen
                                (\_ ->
                                    startDatabase router key options queue
                                        (forget active.job.operation { state | databases = Dict.remove key state.databases, ready = removeKey key state.ready, readySet = Set.remove key state.readySet })
                                )

                    else
                        cancelQueued router key operationId state

                _ ->
                    cancelQueued router key operationId state


cancelQueued router key operationId state =
    case Dict.get key state.databases of
        Just database ->
            let
                ( nextDatabase, removed ) =
                    removeFromDatabase operationId database
            in
            case removed of
                Just job ->
                    Platform.sendToApp router job.cancelled
                        |> Task.andThen (\_ -> Task.succeed (forget job.operation { state | databases = Dict.insert key nextDatabase state.databases }))

                Nothing ->
                    Task.succeed state

        Nothing ->
            Task.succeed state


removeFromDatabase target database =
    case database of
        Pending options queue ->
            let
                ( next, found ) = removeQueue target queue
            in
            ( Pending options next, found )

        Starting options queue ->
            let
                ( next, found ) = removeQueue target queue
            in
            ( Starting options next, found )

        Ready options handle rid active queue ->
            let
                ( next, found ) = removeQueue target queue
            in
            ( Ready options handle rid active next, found )


settleQueue router queue state =
    case dequeue queue of
        Nothing ->
            Task.succeed state

        Just ( job, rest ) ->
            Platform.sendToApp router job.interrupted
                |> Task.andThen (\_ -> settleQueue router rest (forget job.operation state))


forget (Operation operationId) state =
    { state | owners = Dict.remove operationId state.owners, queued = max 0 (state.queued - 1) }


addReady key state =
    if Set.member key state.readySet then
        state

    else
        { state | ready = enqueue key state.ready, readySet = Set.insert key state.readySet }


removeKey key queue =
    queue
        |> queueToList
        |> List.filter ((/=) key)
        |> List.foldl enqueue empty


queueToList queue =
    queue.front ++ List.reverse queue.back


databaseQueueSize key state =
    case Dict.get key state.databases of
        Just (Pending _ queue) -> queue.size
        Just (Starting _ queue) -> queue.size
        Just (Ready _ _ _ _ queue) -> queue.size
        Nothing -> 0


readyQueue state key =
    case Dict.get key state.databases of
        Just (Ready _ _ _ _ queue) -> queue
        _ -> empty


empty =
    { front = [], back = [], size = 0 }


singleton value =
    { front = [ value ], back = [], size = 1 }


enqueue value queue =
    { queue | back = value :: queue.back, size = queue.size + 1 }


dequeue queue =
    case queue.front of
        first :: rest ->
            Just ( first, { queue | front = rest, size = queue.size - 1 } )

        [] ->
            case List.reverse queue.back of
                [] -> Nothing
                first :: rest -> Just ( first, { front = rest, back = [], size = queue.size - 1 } )


removeQueue target queue =
    let
        step job ( kept, found ) =
            let
                (Operation operationId) = job.operation
            in
            if operationId == target && found == Nothing then
                ( kept, Just job )
            else
                ( enqueue job kept, found )
    in
    List.foldl step ( empty, Nothing ) (queueToList queue)


workerCount state =
    Dict.foldl
        (\_ database total ->
            case database of
                Pending _ _ ->
                    total

                Starting _ _ ->
                    total + 1

                Ready _ _ _ _ _ ->
                    total + 1
        )
        0
        state.databases


rotateIdle router state =
    case pendingDatabase state of
        Nothing ->
            Task.succeed state

        Just ( pendingKey, options, pendingQueue ) ->
            case idleDatabase state of
                Nothing ->
                    Task.succeed state

                Just ( idleKey, handle ) ->
                    Runtime.close handle
                        |> Task.andThen
                            (\_ ->
                                startDatabase router pendingKey options pendingQueue
                                    { state | databases = state.databases |> Dict.remove idleKey |> Dict.remove pendingKey }
                            )


pendingDatabase state =
    Dict.foldl
        (\key database found ->
            case ( found, database ) of
                ( Nothing, Pending options queue ) ->
                    Just ( key, options, queue )

                _ ->
                    found
        )
        Nothing
        state.databases


idleDatabase state =
    Dict.foldl
        (\key database found ->
            case ( found, database ) of
                ( Nothing, Ready _ handle _ Nothing queue ) ->
                    if queue.size == 0 then
                        Just ( key, handle )
                    else
                        Nothing

                _ ->
                    found
        )
        Nothing
        state.databases


increment n =
    if n >= 9007199254740990 then 1 else n + 1
