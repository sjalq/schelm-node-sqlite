module Schelm.Node.Sqlite.Decode exposing
    ( Decoder, Error, PathStep(..), Expected(..), Actual(..)
    , succeed, fail, map, map2, map3, map4, map5, map6, map7, map8, apply, andThen
    , field, index, nullable, oneOf, value, string, int, int64, float, number, bytes
    , foldValues
    )

import Bytes exposing (Bytes)
import Schelm.Node.Sqlite.Internal exposing (Int64, Value)

type Decoder a = Decoder (Result String a)
type alias Error = { path : List PathStep, expected : Expected, actual : Actual }
type PathStep = Field String | Index Int | Branch Int
type Expected = AnyValue | TextValue | IntegerValue | RealValue | BlobValue | NullValue | Custom String
type Actual = ActualNull | ActualInteger | ActualReal | ActualText | ActualBlob | Missing | Ambiguous Int
type alias Step a b = Value -> a -> Result String b
succeed a = Decoder (Ok a)
fail reason = Decoder (Err reason)
map f (Decoder a) = Decoder (Result.map f a)
apply : Decoder (a -> b) -> Decoder a -> Decoder b
apply (Decoder f) (Decoder a) = Decoder (Result.map2 (\fn value_ -> fn value_) f a)
map2 : (a -> b -> c) -> Decoder a -> Decoder b -> Decoder c
map2 f a b = apply (apply (succeed f) a) b
map3 f a b c = apply (apply (apply (succeed f) a) b) c
map4 f a b c d = apply (apply (apply (apply (succeed f) a) b) c) d
map5 f a b c d e = apply (apply (apply (apply (apply (succeed f) a) b) c) d) e
map6 f a b c d e g = apply (apply (apply (apply (apply (apply (succeed f) a) b) c) d) e) g
map7 f a b c d e g h = apply (apply (apply (apply (apply (apply (apply (succeed f) a) b) c) d) e) g) h
map8 f a b c d e g h i = apply (apply (apply (apply (apply (apply (apply (apply (succeed f) a) b) c) d) e) g) h) i
andThen f (Decoder result) =
    case result of
        Ok a -> f a
        Err reason -> fail reason
field _ d = d
index _ d = d
nullable (Decoder a) = Decoder (Result.map Just a)
oneOf ds =
    case ds of
        d :: _ -> d
        [] -> fail "empty oneOf"
value = fail "contract"
string = fail "contract"
int = fail "contract"
int64 = fail "contract"
float = fail "contract"
number = fail "contract"
bytes = fail "contract"
foldValues _ seed = succeed seed
