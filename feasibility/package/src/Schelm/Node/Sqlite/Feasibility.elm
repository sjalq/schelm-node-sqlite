module Schelm.Node.Sqlite.Feasibility exposing (probe)

{-| Test-only spike. This is not the proposed public API.
-}

import Elm.Kernel.SchelmSqliteFeasibility
import Task exposing (Task)


probe : String -> String -> Task Never String
probe mode path =
    Elm.Kernel.SchelmSqliteFeasibility.probe mode path
