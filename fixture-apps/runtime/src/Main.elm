port module Main exposing (main)
import Platform
import Schelm.Node.Sqlite as Sqlite
port report : String -> Cmd msg
type Msg = Started Sqlite.Operation | Finished Sqlite.Operation (Result Sqlite.Error Sqlite.Changes)
schema = Sqlite.sql "CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, payload TEXT NOT NULL)" |> Result.withDefault (unsafe ())
main : Program () () Msg
main = Platform.worker { init = \_ -> ((), Sqlite.execute { onStarted = Started, onFinished = Finished } (Sqlite.options Sqlite.memory) (Sqlite.command schema Sqlite.noBindings)), update = \msg model -> case msg of Started _ -> (model, Cmd.none); Finished _ _ -> (model, report "done"), subscriptions = \_ -> Sub.none }
unsafe : () -> a
unsafe _ = unsafe ()
