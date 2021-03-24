{-# language DataKinds #-}
{-# language StandaloneKindSignatures #-}
{-# language TypeFamilies #-}

module Rel8.Type.Num
  ( DBNum, DBIntegral, DBFractional
  )
where

-- base
import Data.Int ( Int16, Int32, Int64 )
import Data.Kind ( Constraint, Type )
import Prelude

-- rel8
import Rel8.Type ( DBType )

-- scientific
import Data.Scientific ( Scientific )


-- | The class of database types that support the @+@, @*@, @-@ operators, and
-- the @abs@, @negate@, @sign@ functions.
type DBNum :: Type -> Constraint
class DBType a => DBNum a
instance DBNum Int16
instance DBNum Int32
instance DBNum Int64
instance DBNum Float
instance DBNum Double
instance DBNum Scientific


type DBIntegral :: Type -> Constraint
class DBNum a => DBIntegral a
instance DBIntegral Int16
instance DBIntegral Int32
instance DBIntegral Int64


-- | The class of database types that support the @/@ operator.
class DBNum a => DBFractional a
instance DBFractional Float
instance DBFractional Double
instance DBFractional Scientific
