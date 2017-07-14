{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE ScopedTypeVariables       #-}

-- |
-- Module      : Asyncly.Threads
-- Copyright   : (c) 2017 Harendra Kumar
--
-- License     : MIT-style
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
module Asyncly.Threads
    ( wait
    , wait_
    , gather

    , waitRecord_
    , waitRecord
    , playRecordings
    )
where

import           Control.Concurrent.STM      (atomically, newTChan)
import           Control.Monad.Catch         (MonadCatch, throwM, try)
import           Control.Monad.IO.Class      (MonadIO (..))
import           Control.Monad.State         (mzero, runStateT)
import           Control.Monad.Trans.Class   (MonadTrans (lift))
import           Data.IORef                  (IORef, atomicModifyIORef,
                                              newIORef, readIORef)

import           Control.Monad.Trans.Recorder (MonadRecorder(..), RecorderT,
                                               Recording, blank, runRecorderT)
import           Asyncly.AsyncT

------------------------------------------------------------------------------
-- Running the monad
------------------------------------------------------------------------------

-- | Run an 'AsyncT m' computation and collect the results generated by each
-- thread of the computation in a list.
waitAsync :: (MonadAsync m, MonadCatch m)
    => (a -> AsyncT m a) -> Maybe (IORef [Recording]) -> AsyncT m a -> m ()
waitAsync finalizer lref m = do
    childChan  <- liftIO $ atomically newTChan
    pendingRef <- liftIO $ newIORef []
    credit     <- liftIO $ newIORef maxBound

    let ctx = initContext childChan pendingRef credit finalizer lref

    r <- try $ runStateT (runAsyncT $ m >>= finalizer) ctx
    e <- handleResult ctx r
    maybe (return ()) throwM e

-- TBD throttling of producer based on conumption rate.

-- | Invoked to store the result of the computation in the context and finish
-- the computation when the computation is done
gatherResult :: MonadAsync m => IORef [a] -> a -> AsyncT m a
gatherResult ref r = do
    liftIO $ atomicModifyIORef ref $ \rs -> (r : rs, ())
    mzero

gather :: (MonadAsync m, MonadCatch m) => AsyncT m a -> AsyncT m [a]
gather m = AsyncT $ do
    resultsRef <- liftIO $ newIORef []
    lift $ waitAsync (gatherResult resultsRef) Nothing m
    r <- liftIO $ readIORef resultsRef
    return $ Just r

-- | Run an 'AsyncT m' computation and collect the results generated by each
-- thread of the computation in a list.
wait :: (MonadAsync m, MonadCatch m) => AsyncT m a -> m [a]
wait m = do
    resultsRef <- liftIO $ newIORef []
    waitAsync (gatherResult resultsRef) Nothing m
    liftIO $ readIORef resultsRef

-- | Run an 'AsyncT m' computation, wait for it to finish and discard the
-- results.
wait_ :: (MonadAsync m, MonadCatch m) => AsyncT m a -> m ()
wait_ m = waitAsync (const mzero) Nothing m

------------------------------------------------------------------------------
-- Logging
------------------------------------------------------------------------------

-- | Compose a computation using previously captured logs
playRecording :: (MonadAsync m, MonadRecorder m)
    => AsyncT m a -> Recording -> AsyncT m a
playRecording m recording = play recording >> m

-- | Resume an 'AsyncT' computation using previously recorded logs. The
-- recording consists of a list of journals one for each thread in the
-- computation.
playRecordings :: (MonadAsync m, MonadRecorder m)
    => AsyncT m a -> [Recording] -> AsyncT m a
playRecordings m logs = each logs >>= playRecording m

-- | Run an 'AsyncT' computation with recording enabled, wait for it to finish
-- returning results for completed threads and recordings for paused threads.
waitRecord :: (MonadAsync m, MonadCatch m)
    => AsyncT m a -> m ([a], [Recording])
waitRecord m = do
    resultsRef <- liftIO $ newIORef []
    lref <- liftIO $ newIORef []
    waitAsync (gatherResult resultsRef) (Just lref) m
    res <- liftIO $ readIORef resultsRef
    logs <- liftIO $ readIORef lref
    return (res, logs)

-- | Run an 'AsyncT' computation with recording enabled, wait for it to finish
-- and discard the results and return the recordings for paused threads, if
-- any.
waitRecord_ :: (MonadAsync m, MonadCatch m)
    => AsyncT (RecorderT m) a -> m [Recording]
waitRecord_ m = do
    lref <- liftIO $ newIORef []
    runRecorderT blank (waitAsync (const mzero) (Just lref) m)
    logs <- liftIO $ readIORef lref
    return logs
