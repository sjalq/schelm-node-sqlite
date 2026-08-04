module Schelm.Node.Sqlite.Decode exposing
    ( Decoder, Error, PathStep, Expected, Actual, Value
    , succeed, fail, map, map2, map3, map4, map5, map6, map7, map8, apply, andThen, oneOf
    , field, index, nullable, value, string, int, int64, float, number, bytes, foldValues
    )

import Bytes exposing (Bytes)
import Schelm.Node.Sqlite.Internal as Internal exposing (Actual(..), Decoder(..), Expected(..), Int64(..), PathStep(..), Value(..))


type alias Decoder a = Internal.Decoder a
type alias Error = Internal.DecodeError
type alias PathStep = Internal.PathStep
type alias Expected = Internal.Expected
type alias Actual = Internal.Actual
type alias Value = Internal.Value

succeed a = Decoder (\_ -> Ok a)
fail reason = Decoder (\_ -> Err (problem [ Branch 0 ] (Custom "application value") Missing (bounded reason)))
map fn (Decoder run) = Decoder (run >> Result.map fn)
apply (Decoder runFn) (Decoder runValue) = Decoder (\row -> Result.map2 (\fn a -> fn a) (runFn row) (runValue row))
map2 fn a b = apply (apply (succeed fn) a) b
map3 fn a b c = apply (map2 fn a b) c
map4 fn a b c d = apply (map3 fn a b c) d
map5 fn a b c d e = apply (map4 fn a b c d) e
map6 fn a b c d e f = apply (map5 fn a b c d e) f
map7 fn a b c d e f g = apply (map6 fn a b c d e f) g
map8 fn a b c d e f g h = apply (map7 fn a b c d e f g) h
andThen fn (Decoder run) = Decoder (\row -> run row |> Result.andThen (\a -> Internal.decode (fn a) row))

oneOf decoders = Decoder (\row -> oneOfHelp row 0 (List.take 16 decoders) [])
oneOfHelp row branch decoders reasons =
    case decoders of
        [] -> Err (problem [ Branch branch ] (Custom "one of decoders") Missing (bounded (String.join "; " (List.reverse reasons))))
        decoder :: rest ->
            case Internal.decode decoder row of
                Ok a -> Ok a
                Err error -> oneOfHelp row (branch + 1) rest (error.reason :: reasons)

field name decoder =
    Decoder
        (\row ->
            case matching name row.columns of
                [ position ] -> at (Field name) position decoder row
                [] -> Err (problem [ Field name ] AnyValue Missing "missing field")
                positions -> Err (problem [ Field name ] AnyValue (Ambiguous (List.length positions)) "ambiguous field")
        )

index position decoder =
    Decoder
        (\row ->
            if position < 0 || position >= List.length row.values then
                Err (problem [ Index position ] AnyValue Missing "index out of range")
            else
                at (Index position) position decoder row
        )

matching name columns = columns |> List.indexedMap Tuple.pair |> List.filter (\(_, candidate) -> candidate == name) |> List.map Tuple.first
at step position decoder row = Internal.decode decoder { columns = [ "value" ], values = row.values |> List.drop position |> List.take 1 } |> Result.mapError (\error -> { error | path = step :: error.path })

value = Decoder (\row -> firstValue row.values)
firstValue values =
    case values of
        first :: _ -> Ok first
        [] -> Err (problem [ Index 0 ] AnyValue Missing "missing value")
string = scalar TextValue textValue
textValue value_ = case value_ of
    Text raw -> Just raw
    _ -> Nothing
int64 = scalar IntegerValue integerValue
integerValue value_ = case value_ of
    Integer raw -> Just raw
    _ -> Nothing
int = int64 |> andThen intFrom64
intFrom64 (Int64 raw) =
    case String.toInt raw of
        Just n -> succeed n
        Nothing -> fail "integer outside Elm Int range"
float = scalar RealValue realValue
realValue value_ = case value_ of
    Real raw -> Just raw
    _ -> Nothing
number = scalar NumberValue numberValue
numberValue value_ = case value_ of
    Real raw -> Just raw
    Integer (Int64 raw) -> String.toFloat raw
    _ -> Nothing
bytes = scalar BlobValue blobValue
blobValue value_ = case value_ of
    Blob raw -> Just raw
    _ -> Nothing
nullable decoder = Decoder (\row -> nullableHelp decoder row)
nullableHelp decoder row =
    case row.values of
        Null :: _ -> Ok Nothing
        _ -> Internal.decode decoder row |> Result.map Just
scalar expected choose = Decoder (\row -> scalarHelp expected choose row.values)
scalarHelp expected choose values =
    case values of
        first :: _ ->
            case choose first of
                Just a -> Ok a
                Nothing -> Err (problem [ Index 0 ] expected (ActualValue (Internal.kind first)) "storage class mismatch")
        [] -> Err (problem [ Index 0 ] expected Missing "missing value")
foldValues step initial = Decoder (\row -> List.foldl (\item state -> state |> Result.andThen (step item)) (Ok initial) row.values |> Result.mapError (\reason -> problem [ Index 0 ] (Custom "value fold") Missing (bounded reason)))
problem path expected actual reason = { path = path, expected = expected, actual = actual, reason = reason }
bounded = String.left 512
