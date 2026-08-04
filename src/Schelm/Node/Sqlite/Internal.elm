module Schelm.Node.Sqlite.Internal exposing
    ( Actual(..), Bindings(..), Command(..), DecodeError, Decoder(..)
    , Expected(..), Int64(..), PathStep(..), Query(..), Row, Value(..), ValueKind(..)
    , decode, kind
    )

import Bytes exposing (Bytes)


type Int64 = Int64 String

type Value = Null | Integer Int64 | Real Float | Text String | Blob Bytes

type ValueKind = NullKind | IntegerKind | RealKind | TextKind | BlobKind

type Bindings = Bindings (List Value)

type Command = Command String Bindings

type Query a = Query String Bindings (Decoder a)

type alias Row = { columns : List String, values : List Value }

type Decoder a = Decoder (Row -> Result DecodeError a)

type PathStep = Field String | Index Int | Branch Int

type Expected = AnyValue | TextValue | IntegerValue | RealValue | NumberValue | BlobValue | Custom String

type Actual = ActualValue ValueKind | Missing | Ambiguous Int

type alias DecodeError = { path : List PathStep, expected : Expected, actual : Actual, reason : String }

decode (Decoder run) = run

kind value =
    case value of
        Null -> NullKind
        Integer _ -> IntegerKind
        Real _ -> RealKind
        Text _ -> TextKind
        Blob _ -> BlobKind
