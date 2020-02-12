{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

-- | This module presents an experimental interface to running queries with an
-- @mtl@-like interface.
module Control.Monad.Rel8
  ( -- * @MonadStatement@
    MonadStatement(..),
    select,
    insert, insert1Returning, insertIgnoringConflicts, insert1IgnoringConflictsReturning,
    update, updateReturning,
    delete,

    -- ** Running @MonadStatement@
    runPostgreSQLStatements, runPostgreSQLStatementsWithDebug,
    PostgreSQLStatementT,

    -- ** @MonadStatement@ syntax
    StatementSyntax(..),

    -- * @MonadTransaction@
    MonadTransaction(..), MonadRollback(..),
    runTransaction,
    runSerializableTransaction,

    -- ** Running @MonadTransaction@
    runPostgreSQLTransactions,
    PostgreSQLTransactionT,

    -- ** @MonadTransaction@ syntax
    TransactionSyntax(..)
  ) where

import Control.Exception (fromException)
import Control.Monad.Free.Church (F, liftF, iterM)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans (MonadTrans, lift)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Resource (MonadUnliftIO, runResourceT)
import UnliftIO.Exception (throwIO, try, mask)
import Data.Int (Int64)
import Data.Foldable (fold, for_)
import Data.Functor (void)
import qualified Data.List.NonEmpty as NonEmpty
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (listToMaybe)
import qualified Database.PostgreSQL.Simple as Pg
import qualified Database.PostgreSQL.Simple.Transaction as Pg
import Opaleye (OnConflict ( DoNothing ), Query)
import qualified Opaleye.Internal.Manipulation as O
import qualified Opaleye.Manipulation as O (arrangeDeleteSql, arrangeUpdateSql, arrangeUpdateReturningSql)
import qualified Opaleye.Sql as O
import qualified Streaming.Prelude as S

import Rel8.Internal
import qualified Rel8.IO

--------------------------------------------------------------------------------
-- | Syntax tree for running individual statements against a database.

data StatementSyntax f where
  Select ::
      Table pg haskell =>
      Query pg -> ([haskell] -> k) -> StatementSyntax k
  InsertReturning ::
      BaseTable table =>
      NonEmpty (table Insert) -> (NonEmpty (table QueryResult) -> k) -> StatementSyntax k
  Insert ::
      BaseTable table =>
      [table Insert] -> (Int64 -> k) -> StatementSyntax k
  InsertIgnoringConflictsReturning ::
      BaseTable table =>
      NonEmpty (table Insert) -> ([table QueryResult] -> k) -> StatementSyntax k
  InsertIgnoringConflicts ::
      BaseTable table =>
      [table Insert] -> (Int64 -> k) -> StatementSyntax k
  Update ::
      (BaseTable table, Predicate bool) =>
      (table Expr -> Expr bool) ->
      (table Expr -> table Expr) -> (Int64 -> k) -> StatementSyntax k
  UpdateReturning ::
      (BaseTable table, Predicate bool) =>
      (table Expr -> Expr bool) ->
      (table Expr -> table Expr) ->
      ([table QueryResult] -> k) -> StatementSyntax k
  Delete ::
      (BaseTable table, Predicate bool) =>
      (table Expr -> Expr bool) -> (Int64 -> k) -> StatementSyntax k

deriving instance Functor StatementSyntax

-- | The class of monads that can run database statements.
class Monad m => MonadStatement m where
  liftStatements :: F StatementSyntax a -> m a

instance {-# OVERLAPPABLE #-} (Monad (t m), MonadTrans t, MonadStatement m) => MonadStatement (t m) where
  liftStatements = lift . liftStatements

select
  :: (MonadStatement m, Table expr haskell)
  => Query expr -> m [haskell]
select q = liftStatements (liftF (Select q id))

insert1Returning
  :: ( MonadStatement m
     , BaseTable table
     )
  => table Insert -> m (table QueryResult)
insert1Returning  = fmap NonEmpty.head . insertReturning . (NonEmpty.:|[])

insertReturning
  :: ( MonadStatement m
     , BaseTable table
     )
  => NonEmpty (table Insert) -> m (NonEmpty (table QueryResult))
insertReturning rows = liftStatements (liftF (InsertReturning rows id))

insert
  :: MonadStatement m
  => BaseTable table => [table Insert] -> m Int64
insert rows = liftStatements (liftF (Insert rows id))

insertIgnoringConflicts
  :: MonadStatement m
  => BaseTable table => [table Insert] -> m Int64
insertIgnoringConflicts rows = liftStatements (liftF (InsertIgnoringConflicts rows id))

insert1IgnoringConflictsReturning
  :: ( MonadStatement m
     , BaseTable table
     )
  => table Insert -> m (Maybe (table QueryResult))
insert1IgnoringConflictsReturning = fmap listToMaybe . insertIgnoringConflictsReturning . pure

insertIgnoringConflictsReturning
  :: ( MonadStatement m
     , BaseTable table
     )
  => NonEmpty (table Insert) -> m [table QueryResult]
insertIgnoringConflictsReturning rows = liftStatements (liftF (InsertIgnoringConflictsReturning rows id))

update
  :: (MonadStatement m, BaseTable table)
  => (table Expr -> Expr Bool)
  -> (table Expr -> table Expr)
  -> m Int64
update f up = liftStatements (liftF (Update f up id))

updateReturning
  :: (MonadStatement m, BaseTable table)
  => (table Expr -> Expr Bool)
  -> (table Expr -> table Expr)
  -> m [table QueryResult]
updateReturning f up = liftStatements (liftF (UpdateReturning f up id))

delete :: (MonadStatement m, BaseTable table, Predicate bool)
       => (table Expr -> Expr bool)
       -> m Int64
delete f = liftStatements (liftF (Delete f id))

--------------------------------------------------------------------------------
-- | The class of monads that can perform a rollback, aborting a transaction.
class Monad m => MonadRollback e m | m -> e where
  abortTransaction :: e -> m a

--------------------------------------------------------------------------------
-- | The syntax of programs that can run transactions.
data TransactionSyntax e k where
  Statements :: Pg.TransactionMode
             -> (Pg.SqlError -> Bool)
             -> (forall m . (MonadStatement m, MonadRollback e m) => m a)
             -> (Either e a -> k)
             -> TransactionSyntax e k

deriving instance Functor (TransactionSyntax e)

-- | The class of monads that can run transactions.
class Monad m => MonadTransaction m where
  liftTransaction :: F (TransactionSyntax e) a -> m a

instance {-# OVERLAPPABLE #-} (Monad (t m), MonadTrans t, MonadTransaction m) => MonadTransaction (t m) where
  liftTransaction = lift . liftTransaction

runTransaction :: MonadTransaction m
               => Pg.TransactionMode
               -> (Pg.SqlError -> Bool)
               -> (forall n. (MonadStatement n, MonadRollback e n) => n a)
               -> m (Either e a)
runTransaction mode shouldRetry t =
  liftTransaction (liftF (Statements mode shouldRetry t id))

runSerializableTransaction
  :: MonadTransaction m
  => (forall n. (MonadStatement n, MonadRollback e n) => n a) -> m (Either e a)
runSerializableTransaction =
  runTransaction
    Pg.TransactionMode {Pg.isolationLevel = Pg.Serializable
                       ,Pg.readWriteMode = Pg.ReadWrite}
    Pg.isSerializationError

--------------------------------------------------------------------------------
newtype PostgreSQLTransactionT m a =
  PostgreSQLTransactionT (ReaderT Pg.Connection m a)
  deriving (Functor,Applicative,Monad)

instance (MonadIO m, MonadUnliftIO m) =>
         MonadTransaction (PostgreSQLTransactionT m) where
  liftTransaction =
    PostgreSQLTransactionT .
    iterM
      (\(Statements mode shouldRetry t k) -> do
         pg <- ask
         out <-
           withTransactionModeRetry
             mode
             shouldRetry
             pg
             (do out <- runPostgreSQLStatements t pg
                 case out of
                   Left {} -> liftIO (Pg.rollback pg)
                   Right {} -> return ()
                 return out)
         k out)

-- | A handler that runs individual statements against a PostgreSQL connection.
-- Again, we just use a reader monad to pass the connection handle around.
newtype PostgreSQLStatementT e m a =
  PostgreSQLStatementT (ExceptT e (ReaderT (Maybe (String -> m ()), Pg.Connection) m) a)
  deriving (Functor,Applicative,Monad)

runPostgreSQLStatements
  :: PostgreSQLStatementT e m a -> Pg.Connection -> m (Either e a)
runPostgreSQLStatements (PostgreSQLStatementT r) pg =
  runReaderT (runExceptT r) (Nothing, pg)

runPostgreSQLStatementsWithDebug
  :: PostgreSQLStatementT e m a -> Pg.Connection -> (String -> m ()) -> m (Either e a)
runPostgreSQLStatementsWithDebug (PostgreSQLStatementT r) pg debug =
  runReaderT (runExceptT r) (Just debug, pg)

instance (MonadIO m, MonadUnliftIO m) => MonadStatement (PostgreSQLStatementT e m) where
  liftStatements =
    PostgreSQLStatementT . ExceptT . fmap Right .
    iterM
      (\op -> do
         (debug, conn) <- ask
         step (maybe (\_ -> pure ()) (lift .) debug) conn op)
    where
      step debug pg (Select q k) = do
        void $ debug $ fold $ O.showSqlExplicit unpackColumns q
        runResourceT (S.toList_ (Rel8.IO.select (Rel8.IO.stream pg) q)) >>= k
      step debug pg (InsertReturning q k) = do
        void $ debug $ O.arrangeInsertManyReturningSql unpackColumns tableDefinition q id Nothing
        runResourceT (NonEmpty.fromList <$> S.toList_ (Rel8.IO.insertReturning (Rel8.IO.stream pg) (NonEmpty.toList q))) >>= k
      step debug pg (Insert q k) = do
        for_ (NonEmpty.nonEmpty q) $ \rows ->
          debug $ O.arrangeInsertManySql tableDefinition rows Nothing
        liftIO (Rel8.IO.insert pg q) >>= k
      step debug pg (InsertIgnoringConflictsReturning q k) = do
        void $ debug $ O.arrangeInsertManyReturningSql unpackColumns tableDefinition q id (Just DoNothing)
        runResourceT (S.toList_ (Rel8.IO.insertIgnoringConflictsReturning (Rel8.IO.stream pg) (NonEmpty.toList q))) >>= k
      step debug pg (InsertIgnoringConflicts q k) = do
        for_ (NonEmpty.nonEmpty q) $ \rows ->
          debug $ O.arrangeInsertManySql tableDefinition rows (Just DoNothing)
        liftIO (Rel8.IO.insertIgnoringConflicts pg q) >>= k
      step debug pg (Update a b k) = do
        void $ debug $ O.arrangeUpdateSql tableDefinitionUpdate b (exprToColumn . a)
        liftIO (Rel8.IO.update pg a b) >>= k
      step debug pg (UpdateReturning a b k) = do
        void $ debug $ O.arrangeUpdateReturningSql unpackColumns tableDefinitionUpdate b (exprToColumn . a) id
        runResourceT (S.toList_ (Rel8.IO.updateReturning (Rel8.IO.stream pg) a b)) >>= k
      step debug pg (Delete q k) = do
        void $ debug $ O.arrangeDeleteSql tableDefinition (exprToColumn . q)
        liftIO (Rel8.IO.delete pg q) >>= k

instance (Monad m) => MonadRollback e (PostgreSQLStatementT e m) where
  abortTransaction l = PostgreSQLStatementT (ExceptT (return (Left l)))

runPostgreSQLTransactions
  :: PostgreSQLTransactionT m a -> Pg.Connection -> m a
runPostgreSQLTransactions (PostgreSQLTransactionT r) = runReaderT r

--------------------------------------------------------------------------------
withTransactionModeRetry :: (MonadIO m, MonadUnliftIO m)
                         => Pg.TransactionMode
                         -> (Pg.SqlError -> Bool)
                         -> Pg.Connection
                         -> m a
                         -> m a
withTransactionModeRetry mode shouldRetry conn act =
  mask $
  \restore ->
    retryLoop $
    try $
    do a <- restore act
       liftIO (Pg.commit conn)
       return a
  where retryLoop act' =
          do liftIO (Pg.beginMode mode conn)
             r <- act'
             case r of
               Left e ->
                 do liftIO (Pg.rollback conn)
                    case fmap shouldRetry (fromException e) of
                      Just True -> retryLoop act'
                      _ -> throwIO e
               Right a -> return a
