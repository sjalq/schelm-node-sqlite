port module Main exposing (main)

import Json.Encode as Encode
import Platform
import Schelm.Node.Sqlite.Feasibility as Feasibility
import Task

port report : String -> Cmd msg

type alias Flags = { mode : String, path : String }
type Msg = Finished String

main : Program Flags () Msg
main =
    Platform.worker
        { init = \flags -> ( (), Task.perform Finished (Feasibility.probe flags.mode flags.path) )
        , update = \(Finished result) _ -> ( (), report result )
        , subscriptions = \_ -> Sub.none
        }
