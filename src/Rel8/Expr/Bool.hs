{-# language DataKinds #-}

module Rel8.Expr.Bool
  ( false, true
  , (&&.), (||.), not_
  , and_, or_
  , boolExpr
  , caseExpr, mcaseExpr
  )
where

-- base
import Data.Foldable ( foldl' )
import Prelude hiding ( null )

-- opaleye
import qualified Opaleye.Internal.HaskellDB.PrimQuery as Opaleye

-- rel8
import Rel8.Expr ( Expr( Expr ) )
import Rel8.Expr.Opaleye
  ( castExpr
  , litPrimExpr
  , mapPrimExpr
  , zipPrimExprsWith
  )
import Rel8.Kind.Nullability ( Nullability( Nullable, NonNullable ) )
import Rel8.Type ( DBType )


false :: Expr 'NonNullable Bool
false = litPrimExpr False


true :: Expr 'NonNullable Bool
true = litPrimExpr True


(&&.) :: Expr nullability Bool -> Expr nullability Bool -> Expr nullability Bool
(&&.) = zipPrimExprsWith (Opaleye.BinExpr Opaleye.OpAnd)
infixr 3 &&.


(||.) :: Expr nullability Bool -> Expr nullability Bool -> Expr nullability Bool
(||.) = zipPrimExprsWith (Opaleye.BinExpr Opaleye.OpOr)
infixr 2 ||.


not_ :: Expr nullability Bool -> Expr nullability Bool
not_ = mapPrimExpr (Opaleye.UnExpr Opaleye.OpNot)


and_ :: Foldable f => f (Expr nullability Bool) -> Expr nullability Bool
and_ = foldl' (&&.) (litPrimExpr True)


or_ :: Foldable f => f (Expr nullability Bool) -> Expr nullability Bool
or_ = foldl' (||.) (litPrimExpr False)


boolExpr :: ()
  => Expr nullability a -> Expr nullability a -> Expr _nullability Bool
  -> Expr nullability a
boolExpr ifFalse ifTrue condition = caseExpr [(condition, ifTrue)] ifFalse


caseExpr :: ()
  => [(Expr _nullability Bool, Expr nullability a)]
  -> Expr nullability a
  -> Expr nullability a
caseExpr branches (Expr fallback) =
  Expr $ Opaleye.CaseExpr (map go branches) fallback
  where
    go (Expr condition, Expr value) = (condition, value)


mcaseExpr :: DBType a
  => [(Expr _nullability Bool, Expr nullability a)]
  -> Expr 'Nullable a
mcaseExpr branches = result
  where
    result = Expr $ Opaleye.CaseExpr (map go branches) fallback
      where
        go (Expr condition, Expr value) = (condition, value)
        Expr fallback =
          castExpr (Expr (Opaleye.ConstExpr Opaleye.NullLit))
            `asProxyTypeOf` result


asProxyTypeOf :: f a -> proxy a -> f a
asProxyTypeOf = const
