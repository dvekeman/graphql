{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
-- | This module provides a representation of a @GraphQL@ Schema in addition to
--   functions for defining and manipulating Schemas.
module Data.GraphQL.Schema
  ( Schema
  , Resolver
  , Subs
  , object
  , object'
  , objectA
  , objectA'
  , scalar
  , scalarA
  , array
  , array'
  , arrayA
  , arrayA'
  , enum
  , enumA
  , resolve
  -- * AST Reexports
  , Field
  , Argument(..)
  , Value(..)
  ) where

import Control.Applicative (Alternative(..))
import Control.Monad (MonadPlus)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State ( get
                                 , put
                                 )
import Data.Foldable (fold)
import Data.GraphQL.Error
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe)
import Data.Monoid (Alt(..))
import qualified Data.Aeson as Aeson
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as T

import Data.GraphQL.AST.Core

-- | A GraphQL schema.
--   @f@ is usually expected to be an instance of 'Alternative'.
type Schema m = NonEmpty (Resolver m)

-- | Resolves a 'Field' into an @Aeson.@'Aeson.Object' with error information
--   (or 'empty'). @f@ is usually expected to be an instance of 'Alternative'.
type Resolver m = Field -> CollectErrsT m Aeson.Object

type Resolvers m = [Resolver m]

type Fields = [Field]

type Arguments = [Argument]

-- | Variable substitution function.
type Subs = Name -> Maybe Value

-- | Create a new 'Resolver' with the given 'Name' from the given 'Resolver's.
object :: MonadPlus m => Name -> Resolvers m -> Resolver m
object name resolvers = objectA name $ \case
  [] -> resolvers
  _  -> empty

-- | Like 'object' but also taking 'Argument's.
objectA
  :: MonadPlus m
  => Name -> (Arguments -> Resolvers m) -> Resolver m
objectA name f fld@(Field _ _ args flds) = withField name (resolve (f args) flds) fld


-- | Create a named 'Resolver' from a list of 'Resolver's.
object' :: MonadPlus m => Name -> m (Resolvers m) -> Resolver m
object' name resolvs = objectA' name $ \case
     [] -> resolvs
     _  -> empty

-- | Like 'object'' but also taking 'Argument's.
objectA'
  :: MonadPlus m
  => Name -> (Arguments -> m (Resolvers m)) -> Resolver m
objectA' name f fld@(Field _ _ args flds) = do
    resolvs <- lift $ f args
    withField name (resolve resolvs flds) fld

-- | A scalar represents a primitive value, like a string or an integer.
scalar :: (MonadPlus m, Aeson.ToJSON a) => Name -> a -> Resolver m
scalar name s = scalarA name $ \case
    [] -> pure s
    _  -> empty

-- | Like 'scalar' but also taking 'Argument's.
scalarA
  :: (MonadPlus m, Aeson.ToJSON a)
  => Name -> (Arguments -> m a) -> Resolver m
scalarA name f fld@(Field _ _ args []) = withField name (lift $ f args) fld
scalarA _ _ _ = empty

array :: MonadPlus m => Name -> [Resolvers m] -> Resolver m
array name resolvers = arrayA name $ \case
    [] -> resolvers
    _  -> empty

-- | Like 'array' but also taking 'Argument's.
arrayA
  :: MonadPlus m
  => Name -> (Arguments -> [Resolvers m]) -> Resolver m
arrayA name f fld@(Field _ _ args sels) =
     withField name (traverse (`resolve` sels) $ f args) fld

-- | Like 'object'' but taking lists of 'Resolver's instead of a single list.
array' :: MonadPlus m => Name -> m [Resolvers m] -> Resolver m
array' name resolvs = arrayA' name $ \case
    [] -> resolvs
    _  -> empty

-- | Like 'array'' but also taking 'Argument's.
arrayA'
  :: MonadPlus m
  => Name -> (Arguments -> m [Resolvers m]) -> Resolver m
arrayA' name f fld@(Field _ _ args sels) = do
     resolvs <- lift $ f args
     withField name (traverse (`resolve` sels) resolvs) fld

-- | Represents one of a finite set of possible values.
--   Used in place of a 'scalar' when the possible responses are easily enumerable.
enum :: MonadPlus m => Name -> m [T.Text] -> Resolver m
enum name enums = enumA name $ \case
     [] -> enums
     _  -> empty

-- | Like 'enum' but also taking 'Argument's.
enumA :: MonadPlus m => Name -> (Arguments -> m [T.Text]) -> Resolver m
enumA name f fld@(Field _ _ args []) = withField name (lift $ f args) fld
enumA _ _ _ = empty

-- | Helper function to facilitate 'Argument' handling.
withField :: (MonadPlus m, Aeson.ToJSON a)
          => Name -> CollectErrsT m a -> Field -> CollectErrsT m (HashMap T.Text Aeson.Value)
withField name v (Field alias name' _ _)
    | name == name' = do
        collection <- HashMap.singleton aliasOrName . Aeson.toJSON <$> runAppendErrs v
        errors <- get
        if null errors
           then return collection
           -- TODO: Report error when Non-Nullable type for field argument.
           else put [] >> return (HashMap.singleton aliasOrName Aeson.Null)
    | otherwise = empty
  where
    aliasOrName = fromMaybe name alias

-- | Takes a list of 'Resolver's and a list of 'Field's and applies each
--   'Resolver' to each 'Field'. Resolves into a value containing the
--   resolved 'Field', or a null value and error information.
resolve :: MonadPlus m => Resolvers m -> Fields -> CollectErrsT m Aeson.Value
resolve resolvers =
    fmap (Aeson.toJSON . fold)
  . traverse (\fld -> getAlt (foldMap (Alt . ($ fld)) resolvers) <|> errmsg fld)
  where
    errmsg (Field alias name _ _) = do
        addErrMsg $ T.unwords ["field", name, "not resolved."]
        return $ HashMap.singleton aliasOrName Aeson.Null
          where
            aliasOrName = fromMaybe name alias
