module Schelm.Node.Sqlite.Internal exposing (Int64(..), Value(..))
import Bytes exposing (Bytes)
type Int64 = Int64 String
type Value = Null | Integer Int64 | Real Float | Text String | Blob Bytes
