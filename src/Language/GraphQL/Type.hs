-- | Reexports non-conflicting type system and schema definitions.
module Language.GraphQL.Type
    ( In.InputField(..)
    , In.InputObjectType(..)
    , Out.Field(..)
    , Out.ObjectType(..)
    , module Language.GraphQL.Type.Definition
    , module Language.GraphQL.Type.Schema
    ) where

import Language.GraphQL.Type.Definition
import Language.GraphQL.Type.Schema (Schema(..))
import qualified Language.GraphQL.Type.In as In
import qualified Language.GraphQL.Type.Out as Out
