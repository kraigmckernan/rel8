{-# language BlockArguments #-}
{-# language DataKinds #-}
{-# language DeriveAnyClass #-}
{-# language DeriveFunctor #-}
{-# language DeriveGeneric #-}
{-# language DerivingVia #-}
{-# language FlexibleContexts #-}
{-# language GADTs #-}
{-# language InstanceSigs #-}
{-# language LambdaCase #-}
{-# language MultiParamTypeClasses #-}
{-# language NamedFieldPuns #-}
{-# language RankNTypes #-}
{-# language ScopedTypeVariables #-}
{-# language TypeApplications #-}
{-# language TypeFamilies #-}
{-# language UndecidableInstances #-}
{-# language UndecidableSuperClasses #-}

module Rel8.Table.MaybeTable
  ( MaybeTable(..)
  , HMaybeTable(..)
  , MaybeTag(..)
  , MakeNull
  , maybeTable
  , optional
  , isNothingTable
  , isJustTable
  , nothingTable
  , justTable
  , catMaybeTable
  , bindMaybeTable
  , traverseMaybeTable
  ) where

-- base
import Data.Semigroup ( Min( Min ), Semigroup )
import GHC.Generics ( Generic )
import Prelude
  ( Applicative( (<*>), pure )
  , Bool( True, False )
  , Bounded
  , Either( Right, Left )
  , Enum
  , Eq
  , Functor
  , Maybe( Just, Nothing )
  , Monad( return, (>>=) )
  , Monoid
  , Ord
  , Read
  , Show
  , ($)
  , (.)
  , (<$>)
  , (<>)
  , (=<<)
  , const
  , error
  , mempty
  )

-- rel8
import qualified Opaleye.Internal.PackMap as Opaleye
import qualified Opaleye.Internal.PrimQuery as Opaleye hiding ( BinOp, aggregate, exists, limit )
import qualified Opaleye.Internal.QueryArr as Opaleye
import qualified Opaleye.Internal.Tag as Opaleye
import qualified Opaleye.Internal.Unpackspec as Opaleye
import qualified Opaleye.Lateral as Opaleye
import Rel8.Context ( Column( I, unI ), Context( Column ), Defaulting( NoDefault ), Meta( Meta ) )
import Rel8.DBType ( DBType( typeInformation ) )
import Rel8.DBType.DBEq ( DBEq, (==.) )
import Rel8.DBType.DBMonoid ( DBMonoid( memptyExpr ) )
import Rel8.DBType.DBOrd ( DBOrd )
import Rel8.DBType.DBSemigroup ( DBSemigroup( (<>.) ) )
import Rel8.DatabaseType ( parseDatabaseType )
import Rel8.Expr ( Expr )
import Rel8.Expr.Bool ( ifThenElse_, not_ )
import Rel8.Expr.Instances ( Column( ExprColumn, fromExprColumn ) )
import Rel8.Expr.Null ( isNull, isNull )
import Rel8.Expr.Opaleye
  ( litExpr
  , litExprWith
  , toPrimExpr
  , unsafeCoerceExpr
  , unsafeNullExpr
  )
import Rel8.HTable ( HAllColumns, HField, HTable, hdbtype, hdict, hfield, hmap, htabulate, htabulateMeta, htraverse )
import Rel8.HTable.HIdentity ( HIdentity( HIdentity ), unHIdentity )
import Rel8.HTable.HMapTable
  ( Eval
  , Exp
  , HMapTable( HMapTable )
  , HMapTableField( HMapTableField )
  , MapInfo( mapInfo )
  , Precompose( Precompose )
  , mapInfo
  )
import Rel8.Info ( Column( InfoColumn, fromInfoColumn ), Info( Null, NotNull ), Nullify, info )
import Rel8.Query ( Query, mapOpaleye, where_ )
import Rel8.Serializable ( ExprFor( pack, unpack ), Serializable, lit )
import Rel8.Table ( Table( Columns, fromColumns, toColumns ) )
import qualified Rel8.Table.Bool as T
import Rel8.Table.Opaleye ( unpackspec )

-- semigroupoids
import Data.Functor.Apply ( Apply( (<.>) ) )
import Data.Functor.Bind ( Bind, (>>-) )


-- | @MaybeTable t@ is the table @t@, but as the result of an outer join. If
-- the outer join fails to match any rows, this is essentialy @Nothing@, and if
-- the outer join does match rows, this is like @Just@. Unfortunately, SQL
-- makes it impossible to distinguish whether or not an outer join matched any
-- rows based generally on the row contents - if you were to join a row
-- entirely of nulls, you can't distinguish if you matched an all null row, or
-- if the match failed.  For this reason @MaybeTable@ contains an extra field -
-- 'nullTag' - to track whether or not the outer join produced any rows.
data MaybeTable t where
  MaybeTable
    :: { -- | Check if this @MaybeTable@ is null. In other words, check if an outer
         -- join matched any rows.
         nullTag :: Expr (Maybe MaybeTag)
       , table :: t
       }
    -> MaybeTable t
  deriving stock Functor


instance (Table Expr (MaybeTable a), Semigroup a) => Semigroup (MaybeTable a) where
  ma <> mb = maybeTable mb (\a -> maybeTable ma (justTable . (a <>)) mb) ma


instance (Table Expr a, Table Expr (MaybeTable a), Semigroup a) => Monoid (MaybeTable a) where
  mempty = nothingTable


instance Apply MaybeTable where
  MaybeTable tag f <.> MaybeTable tag' a = MaybeTable (tag <> tag') (f a)


instance Applicative MaybeTable where
  (<*>) = (<.>)
  pure = justTable


instance Bind MaybeTable where
  MaybeTable tag a >>- f = case f a of
    MaybeTable tag' b -> MaybeTable (tag <> tag') b


instance Monad MaybeTable where
  (>>=) = (>>-)


instance (HTable (Columns (MaybeTable a)), Table Expr a) => Table Expr (MaybeTable a) where
  type Columns (MaybeTable a) = HMaybeTable (Columns a)

  toColumns (MaybeTable x y) = HMaybeTable
    { hnullTag = HIdentity $ ExprColumn x
    , htable = HMapTable $ htabulateMeta f
    }
    where
      f :: forall d x. HField (Columns a) ('Meta d x) -> Precompose MakeNull (Column Expr) ('Meta d x)
      f i = Precompose
        case hfield hdbtype i of
          InfoColumn (NotNull _) ->
            ExprColumn $
            ifThenElse_
              (x ==. lit (Just IsJust))
              (unsafeCoerceExpr (fromExprColumn (hfield (toColumns y) i)))
              unsafeNullExpr

          InfoColumn (Null _) ->
            ExprColumn $
            ifThenElse_
              (x ==. lit (Just IsJust))
              (fromExprColumn (hfield (toColumns y) i))
              unsafeNullExpr

  fromColumns (HMaybeTable (HIdentity x) (HMapTable y)) =
    MaybeTable (fromExprColumn x) (fromColumns (hmap (\(Precompose e) -> ExprColumn (unsafeCoerceExpr (fromExprColumn e))) y))


instance (Table Expr (MaybeTable a), ExprFor a b, Table Expr a) => ExprFor (MaybeTable a) (Maybe b) where
  pack HMaybeTable{ hnullTag = HIdentity (I nullTag), htable = HMapTable t } =
    case nullTag of
      Just IsJust -> Just $ pack @a $ htabulate \i ->
        case hfield hdbtype i of
          InfoColumn (NotNull _) ->
            case hfield t i of
              Precompose (I Nothing)  -> error "Impossible"
              Precompose (I (Just x)) -> I x

          InfoColumn (Null _) ->
            case hfield t i of
              Precompose (I x) -> I x

      _ -> Nothing

  unpack = \case
    Just a -> HMaybeTable
      { hnullTag = HIdentity (I (Just IsJust))
      , htable = htabulateMeta \(HMapTableField i) ->
          case hfield hdbtype i of
            InfoColumn (NotNull _) -> I $ Just $ unI $ hfield unpacked i
            InfoColumn (Null _)    -> hfield unpacked i
      }
      where
        unpacked = unpack @a a

    Nothing -> HMaybeTable
      { hnullTag = HIdentity (I Nothing)
      , htable = htabulate \(HMapTableField i) ->
          case hfield hdbtype i of
            InfoColumn (NotNull _) -> I Nothing
            InfoColumn (Null _)    -> I Nothing
      }


-- | 
-- >>> select c $ pure (pure (lit Nothing) :: MaybeTable (Expr (Maybe Bool)))
-- [Just Nothing]
--
-- > select c $ pure (pure (lit (Just True)) :: MaybeTable (Expr (Maybe Bool)))
-- [Just (Just True)]
--
-- > select c $ pure (nothingTable :: MaybeTable (Expr (Maybe Bool)))
-- [Nothing]
instance (Table Expr (MaybeTable a), Serializable a b) => Serializable (MaybeTable a) (Maybe b) where


-- | @bindMaybeTable f x@ is similar to the monadic bind (@>>=@) operation. It
-- allows you to "extend" an optional query with another query. If either the
-- input or output are 'nothingTable', then the result is 'nothingTable'.
--
-- This is similar to 'traverseMaybeTable', followed by a @join@ on the
-- resulting @MaybeTable@s.
--
-- >>> select c $ bindMaybeTable (optional . values . pure . not_) =<< optional (values [lit True])
-- [Just False]
--
-- >>> select c $ bindMaybeTable (\_ -> return (nothingTable :: MaybeTable (Expr Bool))) =<< optional (values [lit True])
-- [Nothing]
--
-- >>> select c $ bindMaybeTable (optional . values . pure . not_) =<< return (nothingTable :: MaybeTable (Expr Bool))
-- [Nothing]
bindMaybeTable :: (a -> Query (MaybeTable b)) -> MaybeTable a -> Query (MaybeTable b)
bindMaybeTable query (MaybeTable input a) = do
  MaybeTable output b <- query a
  return $ MaybeTable (input <> output) b


-- | Extend an optional query with another query.  This is useful if you want
-- to step through multiple @LEFT JOINs@.
--
-- Note that @traverseMaybeTable@ takes a @a -> Query b@ function, which means
-- you also have the ability to "expand" one row into multiple rows.
--
-- >>> :{
-- duplicate :: Expr Bool -> Query (Expr Bool)
-- duplicate x = unionAll (return x) (return x)
-- :}
--
-- >>> select c $ traverseMaybeTable duplicate =<< optional (values [lit True])
-- [Just True,Just True]
--
-- Note that if the @a -> Query b@ function returns no rows, then the resulting
-- query will also have no rows:
--
-- >>> select c $ traverseMaybeTable (limit 0 . pure) =<< optional (values [lit True])
-- []
--
-- However, regardless of the given @a -> Query b@ function, if the input is
-- @nothingTable@, you will always get exactly one @nothingTable@ back:
--
-- >>> select c $ traverseMaybeTable duplicate (nothingTable :: MaybeTable (Expr Bool))
-- [Nothing]
--
-- >>> select c $ traverseMaybeTable (limit 0 . pure) (nothingTable :: MaybeTable (Expr Bool))
-- [Nothing]
traverseMaybeTable :: (a -> Query b) -> MaybeTable a -> Query (MaybeTable b)
traverseMaybeTable query ma@(MaybeTable input _) = do
  MaybeTable output b <- optional (query =<< catMaybeTable ma)
  where_ $ isNull output ==. isNull input
  return $ MaybeTable input b


-- | Select all rows from another table that match a given predicate. If the
-- predicate is not satisfied, a null 'MaybeTable' is returned.
--
-- @leftJoin t p@ is equivalent to @LEFT JOIN t ON p@.
optional :: Query a -> Query (MaybeTable a)
optional = mapOpaleye $ Opaleye.laterally (Opaleye.QueryArr . go)
  where
    go query (i, left, tag) = (MaybeTable t' a, join, Opaleye.next tag')
      where
        (MaybeTable t a, right, tag') = Opaleye.runSimpleQueryArr (pure <$> query) (i, tag)
        (t', bindings) = Opaleye.run $ Opaleye.runUnpackspec unpackspec (Opaleye.extractAttr "maybe" tag') t
        join = Opaleye.Join Opaleye.LeftJoin (toPrimExpr $ litExpr True) [] bindings left right


-- | Filter out 'MaybeTable's, returning only the tables that are not-null.
--
-- This operation can be used to "undo" the effect of 'optional', which
-- operationally is like turning a @LEFT JOIN@ back into a full @JOIN@.  You
-- can think of this as analogous to 'Data.Maybe.catMaybes'.
--
-- To see this in action, first consider the following 'optional' query:
--
-- >>> :{
-- select c $ do
--   author <- each authorSchema
--   maybeRel8 <- optional $ 
--     each projectSchema 
--       >>= filter (\p -> projectAuthorId p ==. authorId author)
--       >>= filter (\p -> projectName p ==. "rel8")
--   return (authorName author, projectName <$> maybeRel8)
-- :}
-- [("Ollie",Just "rel8"),("Bryan O'Sullivan",Nothing),("Emily Pillmore",Nothing)]
--
-- Here @optional@ is acting as a @LEFT JOIN@. We can turn this into a proper
-- join by using @catMaybeTable@ to filter out rows where the join failed:
--
-- >>> :{
-- select c $ do
--   author <- each authorSchema
--   maybeRel8 <- optional $ 
--     each projectSchema 
--       >>= filter (\p -> projectAuthorId p ==. authorId author)
--       >>= filter (\p -> projectName p ==. "rel8")
--   rel8 <- catMaybeTable maybeRel8
--   return (authorName author, projectName rel8)
-- :}
-- [("Ollie","rel8")]
catMaybeTable :: MaybeTable a -> Query a
catMaybeTable MaybeTable{ nullTag, table } = do
  where_ $ not_ $ isNull nullTag
  return table


-- | Perform case analysis on a 'MaybeTable'. Like 'maybe'.
maybeTable
  :: Table Expr b
  => b -> (a -> b) -> MaybeTable a -> b
maybeTable def f MaybeTable{ nullTag, table } =
  T.ifThenElse_ (nullTag ==. lit (Just IsJust)) (f table) def


isNothingTable :: MaybeTable a -> Expr Bool
isNothingTable = maybeTable (lit True) (const (lit False))


isJustTable :: MaybeTable a -> Expr Bool
isJustTable = not_ . isNothingTable


-- | The null table. Like 'Nothing'.
nothingTable :: forall a. Table Expr a => MaybeTable a
nothingTable = MaybeTable (lit Nothing) $ fromColumns $ htabulate f
  where
    f :: forall x. HField (Columns a) x -> Column Expr x
    f i =
      case hfield hdbtype i of
        InfoColumn NotNull{} -> ExprColumn $ unsafeCoerceExpr (litExprWith (fromInfoColumn (mapInfo @MakeNull (hfield hdbtype i))) Nothing)
        InfoColumn Null{}    -> ExprColumn $ unsafeCoerceExpr (litExprWith (fromInfoColumn (mapInfo @MakeNull (hfield hdbtype i))) Nothing)


-- | Like 'Just'.
justTable :: a -> MaybeTable a
justTable = pure


data MakeNull :: Meta -> Exp Meta


type instance Eval (MakeNull ('Meta d x)) = 'Meta d (Nullify x)


instance MapInfo MakeNull where
  mapInfo = \case
    InfoColumn (NotNull t) -> InfoColumn $ Null t
    InfoColumn (Null t)    -> InfoColumn $ Null t


data HMaybeTable g f = HMaybeTable
  { hnullTag :: HIdentity ('Meta 'NoDefault (Maybe MaybeTag)) f
  , htable :: HMapTable MakeNull g f
  }
  deriving stock Generic


data HMaybeField g a where
  HNullTag :: HMaybeField g ('Meta 'NoDefault (Maybe MaybeTag))
  HMaybeField :: HField (HMapTable MakeNull g) a -> HMaybeField g a


instance HTable g => HTable (HMaybeTable g) where
  type HField (HMaybeTable g) = HMaybeField g

  type HAllColumns (HMaybeTable g) c = (c ('Meta 'NoDefault (Maybe MaybeTag)), HAllColumns (HMapTable MakeNull g) c)

  hfield HMaybeTable{ hnullTag, htable } = \case
    HNullTag      -> unHIdentity hnullTag
    HMaybeField i -> hfield htable i

  htabulate f = HMaybeTable (HIdentity (f HNullTag)) (htabulate (f . HMaybeField))

  htraverse f HMaybeTable{ hnullTag, htable } =
    HMaybeTable <$> htraverse f hnullTag <.> htraverse f htable

  hdict = HMaybeTable hdict hdict

  hdbtype = HMaybeTable
    { hnullTag = HIdentity $ InfoColumn info
    , htable = HMapTable $ htabulate $ Precompose . mapInfo @MakeNull . hfield hdbtype
    }


data MaybeTag = IsJust
  deriving stock (Eq, Ord, Read, Show, Enum, Bounded)
  deriving (Semigroup, Monoid) via (Min MaybeTag)
  deriving anyclass (DBEq, DBOrd)


instance DBType MaybeTag where
  typeInformation = parseDatabaseType to from typeInformation
    where
      to False = Left "MaybeTag can't be false"
      to True = Right IsJust
      from _ = True


instance DBSemigroup MaybeTag where
  _ <>. _ = lit IsJust


instance DBMonoid MaybeTag where
  memptyExpr = lit IsJust
