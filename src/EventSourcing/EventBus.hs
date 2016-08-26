module EventSourcing.EventBus
  ( Handler
  , EventBus (..)
  , eventBus
  , registerHandler
  , registerProjection
  , publishEvent
  , storeAndPublishEvent
  ) where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class
import Pipes
import Pipes.Concurrent

import EventSourcing.Projection
import EventSourcing.Store
import EventSourcing.UUID

type Handler event m = StoredEvent event -> m ()

data EventBus event =
  EventBus
  { eventBusQueues :: TVar [Output (StoredEvent event)]
  }

eventBus :: IO (EventBus event)
eventBus = EventBus <$> atomically (newTVar [])

registerHandler
  :: (SequencedSerializedEventStore IO store serialized event)
  => store -> EventBus event -> Handler event IO -> IO ()
registerHandler = registerHandlerStart 0

registerHandlerStart
  :: (SequencedSerializedEventStore IO store serialized event)
  => SequenceNumber -> store -> EventBus event -> Handler event IO -> IO ()
registerHandlerStart seqNum store (EventBus queuesTVar) handler = do
  (output, input) <- spawn unbounded
  _ <- async $ do
    startPipe <- getAllSerializedEventsPipe store seqNum
    runEffect $ (startPipe >> fromInput input) >-> handlerConsumer handler
    performGC
  atomically $ modifyTVar' queuesTVar ((:) output)

registerProjection
  :: (ProjectionStore IO projstore proj, SequencedSerializedEventStore IO store serialized event)
  => store -> EventBus event -> projstore -> (StoredEvent event -> StoredEvent (Event proj)) -> IO ()
registerProjection eventStore bus projStore transformer = do
  seqNum <- latestApplied projStore
  let handler event = applyEvents projStore [transformer event]
  registerHandlerStart seqNum eventStore bus handler

handlerConsumer :: (Monad m) => Handler event m -> Consumer (StoredEvent event) m ()
handlerConsumer handler = forever $ await >>= lift . handler

publishEvent :: (MonadIO m) => EventBus event -> StoredEvent event -> m ()
publishEvent EventBus{..} event =
  liftIO $ void $ atomically $ do
    queues <- readTVar eventBusQueues
    mapM_ (`send` event) queues

storeAndPublishEvent
  :: (MonadIO m, SerializedEventStore m store serialized event)
  => store -> EventBus event -> UUID -> event -> m ()
storeAndPublishEvent store bus uuid event = do
  storedEvents <- storeSerializedEvents store uuid [event]
  mapM_ (publishEvent bus) storedEvents
