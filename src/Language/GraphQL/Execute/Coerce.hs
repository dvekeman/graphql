{-# LANGUAGE OverloadedStrings #-}

-- | Types and functions used for input and result coercion.
module Language.GraphQL.Execute.Coerce
    ( VariableValue(..)
    , coerceInputLiterals
    ) where

import qualified Data.Aeson as Aeson
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Set as Set
import qualified Data.Text.Lazy as Text.Lazy
import qualified Data.Text.Lazy.Builder as Text.Builder
import qualified Data.Text.Lazy.Builder.Int as Text.Builder
import Data.Scientific (toBoundedInteger, toRealFloat)
import Language.GraphQL.AST.Document (Name)
import qualified Language.GraphQL.Type.In as In
import Language.GraphQL.Schema
import Language.GraphQL.Type.Definition

-- | Since variables are passed separately from the query, in an independent
-- format, they should be first coerced to the internal representation used by
-- this implementation.
class VariableValue a where
    -- | Only a basic, format-specific, coercion must be done here. Type
    -- correctness or nullability shouldn't be validated here, they will be
    -- validated later. The type information is provided only as a hint.
    --
    -- For example @GraphQL@ prohibits the coercion from a 't:Float' to an
    -- 't:Int', but @JSON@ doesn't have integers, so whole numbers should be
    -- coerced to 't:Int` when receiving variables as a JSON object. The same
    -- holds for 't:Enum'. There are formats that support enumerations, @JSON@
    -- doesn't, so the type information is given and 'coerceVariableValue' can
    -- check that an 't:Enum' is expected and treat the given value
    -- appropriately. Even checking whether this value is a proper member of the
    -- corresponding 't:Enum' type isn't required here, since this can be
    -- checked independently.
    --
    -- Another example is an @ID@. @GraphQL@ explicitly allows to coerce
    -- integers and strings to @ID@s, so if an @ID@ is received as an integer,
    -- it can be left as is and will be coerced later.
    --
    -- If a value cannot be coerced without losing information, 'Nothing' should
    -- be returned, the coercion will fail then and the query won't be executed.
    coerceVariableValue
        :: In.Type -- ^ Expected type (variable type given in the query).
        -> a -- ^ Variable value being coerced.
        -> Maybe In.Value -- ^ Coerced value on success, 'Nothing' otherwise.

instance VariableValue Aeson.Value where
    coerceVariableValue _ Aeson.Null = Just In.Null
    coerceVariableValue (In.ScalarBaseType scalarType) value
        | (Aeson.String stringValue) <- value = Just $ In.String stringValue
        | (Aeson.Bool booleanValue) <- value = Just $ In.Boolean booleanValue
        | (Aeson.Number numberValue) <- value
        , (ScalarType "Float" _) <- scalarType =
            Just $ In.Float $ toRealFloat numberValue
        | (Aeson.Number numberValue) <- value = -- ID or Int
            In.Int <$> toBoundedInteger numberValue
    coerceVariableValue (In.EnumBaseType _) (Aeson.String stringValue) =
        Just $ In.Enum stringValue
    coerceVariableValue (In.InputObjectBaseType objectType) value
        | (Aeson.Object objectValue) <- value = do
            let (In.InputObjectType _ _ inputFields) = objectType
            (newObjectValue, resultMap) <- foldWithKey objectValue inputFields
            if HashMap.null newObjectValue
                then Just $ In.Object resultMap
                else Nothing
      where
        foldWithKey objectValue = HashMap.foldrWithKey matchFieldValues
            $ Just (objectValue, HashMap.empty)
        matchFieldValues _ _ Nothing = Nothing
        matchFieldValues fieldName inputField (Just (objectValue, resultMap)) =
            let (In.InputField _ fieldType _) = inputField
                insert = flip (HashMap.insert fieldName) resultMap
                newObjectValue = HashMap.delete fieldName objectValue
             in case HashMap.lookup fieldName objectValue of
                    Just variableValue -> do
                        coerced <- coerceVariableValue fieldType variableValue
                        pure (newObjectValue, insert coerced)
                    Nothing -> Just (objectValue, resultMap)
    coerceVariableValue (In.ListBaseType listType) value
        | (Aeson.Array arrayValue) <- value = In.List
            <$> foldr foldVector (Just []) arrayValue
        | otherwise = coerceVariableValue listType value
      where
        foldVector _ Nothing = Nothing
        foldVector variableValue (Just list) = do
            coerced <- coerceVariableValue listType variableValue
            pure $ coerced : list 
    coerceVariableValue _ _ = Nothing

-- | Coerces operation arguments according to the input coercion rules for the
--   corresponding types.
coerceInputLiterals
    :: HashMap Name In.Type
    -> HashMap Name In.Value
    -> Maybe Subs
coerceInputLiterals variableTypes variableValues =
    foldWithKey operator variableTypes
  where
    operator variableName variableType resultMap =
        HashMap.insert variableName
        <$> (lookupVariable variableName >>= coerceInputLiteral variableType)
        <*> resultMap
    coerceInputLiteral (In.NamedScalarType type') value
        | (In.String stringValue) <- value
        , (ScalarType "String" _) <- type' = Just $ In.String stringValue
        | (In.Boolean booleanValue) <- value
        , (ScalarType "Boolean" _) <- type' = Just $ In.Boolean booleanValue
        | (In.Int intValue) <- value
        , (ScalarType "Int" _) <- type' = Just $ In.Int intValue
        | (In.Float floatValue) <- value
        , (ScalarType "Float" _) <- type' = Just $ In.Float floatValue
        | (In.Int intValue) <- value
        , (ScalarType "Float" _) <- type' =
            Just $ In.Float $ fromIntegral intValue
        | (In.String stringValue) <- value
        , (ScalarType "ID" _) <- type' = Just $ In.String stringValue
        | (In.Int intValue) <- value
        , (ScalarType "ID" _) <- type' = Just $ decimal intValue
    coerceInputLiteral (In.NamedEnumType type') (In.Enum enumValue)
        | member enumValue type' = Just $ In.Enum enumValue
    coerceInputLiteral (In.NamedInputObjectType type') (In.Object _) = 
        let (In.InputObjectType _ _ inputFields) = type'
            in In.Object <$> foldWithKey matchFieldValues inputFields
    coerceInputLiteral _ _ = Nothing
    member value (EnumType _ _ members) = Set.member value members
    matchFieldValues fieldName (In.InputField _ type' defaultValue) resultMap =
        case lookupVariable fieldName of
            Just In.Null
                | In.isNonNullType type' -> Nothing
                | otherwise ->
                    HashMap.insert fieldName In.Null <$> resultMap
            Just variableValue -> HashMap.insert fieldName
                <$> coerceInputLiteral type' variableValue
                <*> resultMap
            Nothing
                | Just value <- defaultValue ->
                    HashMap.insert fieldName value <$> resultMap
                | Nothing <- defaultValue
                , In.isNonNullType type' -> Nothing
                | otherwise -> resultMap
    lookupVariable = flip HashMap.lookup variableValues
    foldWithKey f = HashMap.foldrWithKey f (Just HashMap.empty)
    decimal = In.String
        . Text.Lazy.toStrict
        . Text.Builder.toLazyText
        . Text.Builder.decimal
