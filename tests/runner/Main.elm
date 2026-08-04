port module Main exposing (main)

import Platform
import Schelm.Node.Sqlite.Decode as Decode
import Schelm.Node.Sqlite.Int64 as Int64
import Schelm.Node.Sqlite.Internal as Internal


port report : { failures : Int, tests : Int } -> Cmd msg


type Msg
    = Never


main =
    Platform.worker
        { init = \() -> ( (), run )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


run =
    let
        cases =
            [ Int64.canonical "0"
            , Int64.canonical "1"
            , Int64.canonical "-1"
            , Int64.canonical "9223372036854775807"
            , Int64.canonical "-9223372036854775808"
            , not (Int64.canonical "9223372036854775808")
            , not (Int64.canonical "-9223372036854775809")
            , not (Int64.canonical "99999999999999999999999999999999999999999999999999")
            , not (Int64.canonical "-99999999999999999999999999999999999999999999999999")
            , not (Int64.canonical "00")
            , not (Int64.canonical "01")
            , not (Int64.canonical "-01")
            , not (Int64.canonical "+1")
            , not (Int64.canonical "-0")
            , not (Int64.canonical "")
            , not (Int64.canonical " 1")
            , not (Int64.canonical "1 ")
            , not (Int64.canonical "1x")
            , Internal.decode (Decode.field "name" Decode.string) { columns = [ "name" ], values = [ Internal.Text "ok" ] } == Ok "ok"
            , Internal.decode (Decode.field "value" (Decode.nullable Decode.int64)) { columns = [ "value" ], values = [ Internal.Null ] } == Ok Nothing
            , case Internal.decode (Decode.field "missing" Decode.string) { columns = [ "name" ], values = [ Internal.Text "ok" ] } of
                Err _ -> True
                Ok _ -> False
            ]
    in
    report
        { failures = List.length (List.filter not cases)
        , tests = List.length cases
        }
