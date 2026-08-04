port module Main exposing (main)

import Platform
import Schelm.Node.Sqlite as Sqlite

port report : String -> Cmd msg

type Msg = Started Sqlite.Operation | Finished Sqlite.Operation (Result Sqlite.Error Sqlite.Changes)

schema =
    Sqlite.sql "CREATE TABLE IF NOT EXISTS smoke(id INTEGER PRIMARY KEY)"
        |> Result.withDefault
            (Sqlite.sql "SELECT 1"
                |> Result.withDefault (unsafeValue ())
            )


unsafeValue : () -> a
unsafeValue _ =
    unsafeValue ()

main =
    Platform.worker
        { init = \() ->
            ( ()
            , Sqlite.execute
                { onStarted = Started, onFinished = Finished }
                (Sqlite.options Sqlite.memory)
                (Sqlite.command schema Sqlite.noBindings)
                |> Cmd.map identity
            )
        , update = \msg model ->
            case msg of
                Started _ ->
                    ( model, Cmd.none )

                Finished _ _ ->
                    ( model, report "done" )
        , subscriptions = \_ -> Sub.none
        }
