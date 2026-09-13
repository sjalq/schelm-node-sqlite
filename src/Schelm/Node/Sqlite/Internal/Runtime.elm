module Schelm.Node.Sqlite.Internal.Runtime exposing (Handle, RawError, RawResponse, Request, WireValue(..), close, request, start)

import Elm.Kernel.SchelmSqlite
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


type Handle = Handle

type alias RawError = { kind : String, message : String, code : Int }
type alias RawResponse = { kind : String, changedRows : Int, lastInsertRowId : String, columns : List String, rows : List (List WireValue) }
type WireValue = WireNull | WireInteger String | WireReal Float | WireText String | WireBlob (List Int)
type alias Request = { id : Int, operation : String, mutating : Bool, inTransaction : Bool, sql : String, bindings : List Encode.Value, rowLimit : Int, byteLimit : Int, mode : String, options : Encode.Value }

start : Encode.Value -> Task RawError Handle
start options = Elm.Kernel.SchelmSqlite.start (Encode.encode 0 options) |> Task.mapError decodeError

request : Handle -> Request -> Task RawError RawResponse
request handle value =
    Elm.Kernel.SchelmSqlite.request handle (Encode.encode 0 (encodeRequest value))
        |> Task.mapError decodeError
        |> Task.andThen (decodeString responseDecoder)

close : Handle -> Task Never ()
close = Elm.Kernel.SchelmSqlite.close

encodeRequest r =
    Encode.object
        [ ( "v", Encode.int 1 ), ( "id", Encode.int r.id ), ( "op", Encode.string r.operation )
        , ( "mutating", Encode.bool r.mutating ), ( "inTransaction", Encode.bool r.inTransaction )
        , ( "sql", Encode.string r.sql ), ( "bindings", Encode.list identity r.bindings )
        , ( "rowLimit", Encode.int r.rowLimit ), ( "byteLimit", Encode.int r.byteLimit )
        , ( "mode", Encode.string r.mode ), ( "options", r.options )
        ]

decodeString decoder raw =
    case Decode.decodeString decoder raw of
        Ok value -> Task.succeed value
        Err _ -> Task.fail { kind = "protocol-failure", message = "invalid supervisor response", code = 0 }

decodeError raw =
    case Decode.decodeString errorDecoder raw of
        Ok value -> value
        Err _ -> { kind = "protocol-failure", message = "invalid runtime error", code = 0 }

errorDecoder = Decode.map3 RawError (Decode.field "kind" Decode.string) (Decode.field "message" Decode.string) (Decode.field "code" Decode.int)


-- Decode.field fails on an absent key before an inner oneOf can default it.
-- Query/begin/commit/rollback done frames historically omitted changedRows and
-- lastInsertRowId; wrap oneOf around field so those frames still decode.
optionalField name decoder fallback =
    Decode.oneOf [ Decode.field name decoder, Decode.succeed fallback ]


responseDecoder =
    Decode.map5 RawResponse
        (Decode.field "kind" Decode.string)
        (optionalField "changedRows" Decode.int 0)
        (optionalField "lastInsertRowId" Decode.string "0")
        (optionalField "columns" (Decode.list Decode.string) [])
        (optionalField "rows" (Decode.list (Decode.list wireDecoder)) [])
wireDecoder =
    Decode.field "t" Decode.string |> Decode.andThen (\tag -> case tag of
        "null" -> Decode.succeed WireNull
        "integer" -> Decode.map WireInteger (Decode.field "v" Decode.string)
        "real" -> Decode.map WireReal (Decode.field "v" Decode.float)
        "text" -> Decode.map WireText (Decode.field "v" Decode.string)
        "blob" -> Decode.map WireBlob (Decode.field "v" (Decode.list Decode.int))
        _ -> Decode.fail "wire value")
