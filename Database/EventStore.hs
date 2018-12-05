{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
--------------------------------------------------------------------------------
-- |
-- Module : Database.EventStore
-- Copyright : (C) 2014 Yorick Laupa
-- License : (see the file LICENSE)
--
-- Maintainer : Yorick Laupa <yo.eight@gmail.com>
-- Stability : provisional
-- Portability : non-portable
--
--------------------------------------------------------------------------------
module Database.EventStore
    ( -- * Connection
      Connection
    , ConnectionType(..)
    , Credentials
    , Settings(..)
    , Retry
    , atMost
    , keepRetrying
    , credentials
    , defaultSettings
    , defaultSSLSettings
    , connect
    , shutdown
    , waitTillClosed
    , connectionSettings
      -- * Cluster Connection
    , ClusterSettings(..)
    , DnsServer(..)
    , GossipSeed
    , gossipSeed
    , gossipSeedWithHeader
    , gossipSeedHost
    , gossipSeedHeader
    , gossipSeedPort
    , gossipSeedClusterSettings
    , dnsClusterSettings
      -- * Event
    , Event
    , EventData
    , EventType(..)
    , createEvent
    , withJson
    , withJsonAndMetadata
    , withBinary
    , withBinaryAndMetadata
     -- * Event number
    , EventNumber
    , streamStart
    , streamEnd
    , eventNumber
    , rawEventNumber
    , eventNumberToInt64
     -- * Common Operation types
    , OperationMaxAttemptReached(..)
     -- * Read Operations
    , StreamMetadataResult(..)
    , BatchResult(..)
    , ResolveLink(..)
    , readEvent
    , readEventsBackward
    , readEventsForward
    , getStreamMetadata
      -- * Write Operations
    , StreamACL(..)
    , StreamMetadata(..)
    , getCustomPropertyValue
    , getCustomProperty
    , emptyStreamACL
    , emptyStreamMetadata
    , deleteStream
    , sendEvent
    , sendEvents
    , setStreamMetadata
      -- * Builder
    , Builder
      -- * Stream ACL Builder
    , StreamACLBuilder
    , buildStreamACL
    , modifyStreamACL
    , setReadRoles
    , setReadRole
    , setWriteRoles
    , setWriteRole
    , setDeleteRoles
    , setDeleteRole
    , setMetaReadRoles
    , setMetaReadRole
    , setMetaWriteRoles
    , setMetaWriteRole
      -- * Stream Metadata Builder
    , StreamMetadataBuilder
    , buildStreamMetadata
    , modifyStreamMetadata
    , setMaxCount
    , setMaxAge
    , setTruncateBefore
    , setCacheControl
    , setACL
    , modifyACL
    , setCustomProperty
      -- * Transaction
    , Transaction
    , TransactionId
    , startTransaction
    , transactionId
    , transactionCommit
    , transactionRollback
    , transactionWrite
      -- * Subscription
    , SubscriptionClosed(..)
    , SubscriptionId
    , SubscriptionStream(..)
    , Subscription
    , SubDropReason(..)
    , SubDetails
    , waitConfirmation
    , unsubscribeConfirmed
    , unsubscribeConfirmedSTM
    , waitUnsubscribeConfirmed
    , nextEventMaybeSTM
    , getSubscriptionDetailsSTM
    , unsubscribe
      -- * Volatile Subscription
    , RegularSubscription
    , subscribe
    , getSubscriptionId
    , nextEvent
    , nextEventMaybe
      -- * Catch-up Subscription
    , CatchupSubscription
    , subscribeFrom
    , waitTillCatchup
    , hasCaughtUp
    , hasCaughtUpSTM
     -- * Persistent Subscription
    , PersistentSubscription
    , PersistentSubscriptionSettings(..)
    , SystemConsumerStrategy(..)
    , NakAction(..)
    , PersistActionException(..)
    , acknowledge
    , acknowledgeEvents
    , failed
    , eventsFailed
    , notifyEventsProcessed
    , notifyEventsFailed
    , defaultPersistentSubscriptionSettings
    , createPersistentSubscription
    , updatePersistentSubscription
    , deletePersistentSubscription
    , connectToPersistentSubscription
     -- * Results
    , Slice(..)
    , sliceEvents
    , sliceEOS
    , sliceNext
    , emptySlice
    , AllSlice
    , Op.DeleteResult(..)
    , WriteResult(..)
    , ReadResult(..)
    , RecordedEvent(..)
    , Op.ReadEvent(..)
    , StreamSlice
    , Position(..)
    , ReadDirection(..)
    , ResolvedEvent(..)
    , OperationError(..)
    , StreamId(..)
    , StreamName(..)
    , isAllStream
    , isEventResolvedLink
    , resolvedEventOriginal
    , resolvedEventDataAsJson
    , resolvedEventOriginalStreamId
    , resolvedEventOriginalId
    , resolvedEventOriginalEventNumber
    , recordedEventDataAsJson
    , positionStart
    , positionEnd
      -- * Logging
    , LogLevel(..)
    , LogType(..)
    , LoggerFilter(..)
      -- * Misc
    , Command
    , DropReason(..)
    , ExpectedVersion
    , anyVersion
    , noStreamVersion
    , emptyStreamVersion
    , exactEventVersion
    , streamExists
    , msDiffTime
      -- * Re-export
    , (<>)
    , NonEmpty(..)
    , nonEmpty
    , TLSSettings
    , NominalDiffTime
    ) where

--------------------------------------------------------------------------------
import Prelude (String)
import Data.Int
import Data.Maybe
import Data.Time (NominalDiffTime)

--------------------------------------------------------------------------------
import Data.List.NonEmpty(NonEmpty(..), nonEmpty)
import Network.Connection (TLSSettings)

--------------------------------------------------------------------------------
import           Database.EventStore.Internal.Callback
import           Database.EventStore.Internal.Command
import           Database.EventStore.Internal.Communication
import           Database.EventStore.Internal.Connection (connectionBuilder)
import           Database.EventStore.Internal.Control hiding (subscribe)
import           Database.EventStore.Internal.Discovery
import           Database.EventStore.Internal.Exec
import           Database.EventStore.Internal.Subscription.Api
import           Database.EventStore.Internal.Subscription.Catchup
import           Database.EventStore.Internal.Subscription.Message
import           Database.EventStore.Internal.Subscription.Persistent
import           Database.EventStore.Internal.Subscription.Types
import           Database.EventStore.Internal.Subscription.Regular
import           Database.EventStore.Internal.Logger
import           Database.EventStore.Internal.Manager.Operation.Registry
import           Database.EventStore.Internal.Operation (OperationError(..))
import qualified Database.EventStore.Internal.Operations as Op
import           Database.EventStore.Internal.Operation.Read.Common
import           Database.EventStore.Internal.Operation.Write.Common
import           Database.EventStore.Internal.Prelude
import           Database.EventStore.Internal.Stream
import           Database.EventStore.Internal.Types

--------------------------------------------------------------------------------
-- Connection
--------------------------------------------------------------------------------
-- | Gathers every connection type handled by the client.
data ConnectionType
    = Static String Int
      -- ^ HostName and Port.
    | Cluster ClusterSettings
    | Dns ByteString (Maybe DnsServer) Int
      -- ^ Domain name, optional DNS server and port.

--------------------------------------------------------------------------------
-- | Represents a connection to a single EventStore node.
data Connection
    = Connection
      { _exec     :: Exec
      , _settings :: Settings
      , _type     :: ConnectionType
      }

--------------------------------------------------------------------------------
-- | Creates a new 'Connection' to a single node. It maintains a full duplex
--   connection to the EventStore. An EventStore 'Connection' operates quite
--   differently than say a SQL connection. Normally when you use an EventStore
--   connection you want to keep the connection open for a much longer of time
--   than when you use a SQL connection.
--
--   Another difference  is that with the EventStore 'Connection' all operations
--   are handled in a full async manner (even if you call the synchronous
--   behaviors). Many threads can use an EvenStore 'Connection' at the same time
--   or a single thread can make many asynchronous requests. To get the most
--   performance out of the connection it is generally recommended to use it in
--   this way.
connect :: Settings -> ConnectionType -> IO Connection
connect settings@Settings{..} tpe = do
    disc <- case tpe of
        Static host port -> return $ staticEndPointDiscovery host port
        Cluster setts    -> clusterDnsEndPointDiscovery setts
        Dns dom srv port -> return $ simpleDnsEndPointDiscovery dom srv port

    logRef  <- newLoggerRef s_loggerType s_loggerFilter s_loggerDetailed
    mainBus <- newBus logRef settings
    builder <- connectionBuilder settings
    exec    <- newExec settings mainBus builder disc
    return $ Connection exec settings tpe

--------------------------------------------------------------------------------
-- | Waits the 'Connection' to be closed.
waitTillClosed :: Connection -> IO ()
waitTillClosed Connection{..} = execWaitTillClosed _exec

--------------------------------------------------------------------------------
-- | Returns a 'Connection' 's 'Settings'.
connectionSettings :: Connection -> Settings
connectionSettings = _settings

--------------------------------------------------------------------------------
-- | Asynchronously closes the 'Connection'.
shutdown :: Connection -> IO ()
shutdown Connection{..} = publishWith _exec SystemShutdown

--------------------------------------------------------------------------------
-- | Sends a single 'Event' to given stream.
sendEvent :: Connection
          -> StreamName
          -> ExpectedVersion
          -> Event
          -> Maybe Credentials
          -> IO (Async WriteResult)
sendEvent mgr evt_stream exp_ver evt cred =
    sendEvents mgr evt_stream exp_ver [evt] cred

--------------------------------------------------------------------------------
-- | Sends a list of 'Event' to given stream.
sendEvents :: Connection
           -> StreamName
           -> ExpectedVersion
           -> [Event]
           -> Maybe Credentials
           -> IO (Async WriteResult)
sendEvents Connection{..} evt_stream exp_ver evts cred = do
    p <- newPromise
    let op = Op.writeEvents _settings (streamIdRaw evt_stream) exp_ver cred evts
    publishWith _exec (SubmitOperation p op)
    async (retrieve p)

--------------------------------------------------------------------------------
-- | Deletes given stream.
deleteStream :: Connection
             -> StreamName
             -> ExpectedVersion
             -> Maybe Bool       -- ^ Hard delete
             -> Maybe Credentials
             -> IO (Async Op.DeleteResult)
deleteStream Connection{..} evt_stream exp_ver hard_del cred = do
    p <- newPromise
    let op = Op.deleteStream _settings (streamIdRaw evt_stream) exp_ver hard_del cred
    publishWith _exec (SubmitOperation p op)
    async (retrieve p)

--------------------------------------------------------------------------------
-- | Represents a multi-request transaction with the EventStore.
data Transaction =
    Transaction
    { _tStream  :: Text
    , _tTransId :: TransactionId
    , _tExpVer  :: ExpectedVersion
    , _tConn    :: Connection
    }

--------------------------------------------------------------------------------
-- | The id of a 'Transaction'.
newtype TransactionId =
    TransactionId { _unTransId :: Int64 }
    deriving (Eq, Ord, Show)

--------------------------------------------------------------------------------
-- | Gets the id of a 'Transaction'.
transactionId :: Transaction -> TransactionId
transactionId = _tTransId

--------------------------------------------------------------------------------
-- | Starts a transaction on given stream.
startTransaction :: Connection
                 -> StreamName            -- ^ Stream name
                 -> ExpectedVersion
                 -> Maybe Credentials
                 -> IO (Async Transaction)
startTransaction conn@Connection{..} evt_stream exp_ver cred = do
    p <- newPromise
    let op = Op.transactionStart _settings (streamIdRaw evt_stream) exp_ver cred
    publishWith _exec (SubmitOperation p op)
    async $ do
        tid <- retrieve p
        return Transaction
               { _tStream  = streamIdRaw evt_stream
               , _tTransId = TransactionId tid
               , _tExpVer  = exp_ver
               , _tConn    = conn
               }

--------------------------------------------------------------------------------
-- | Asynchronously writes to a transaction in the EventStore.
transactionWrite :: Transaction
                 -> [Event]
                 -> Maybe Credentials
                 -> IO (Async ())
transactionWrite Transaction{..} evts cred = do
    p <- newPromise
    let Connection{..} = _tConn
        raw_id = _unTransId _tTransId
        op     = Op.transactionWrite _settings _tStream _tExpVer raw_id evts cred
    publishWith _exec (SubmitOperation p op)
    async (retrieve p)

--------------------------------------------------------------------------------
-- | Asynchronously commits this transaction.
transactionCommit :: Transaction -> Maybe Credentials -> IO (Async WriteResult)
transactionCommit Transaction{..} cred = do
    p <- newPromise
    let Connection{..} = _tConn
        raw_id = _unTransId _tTransId
        op     = Op.transactionCommit _settings _tStream _tExpVer raw_id cred
    publishWith _exec (SubmitOperation p op)
    async (retrieve p)

--------------------------------------------------------------------------------
-- | There isn't such of thing in EventStore parlance. Basically, if you want to
--   rollback, you just have to not 'transactionCommit' a 'Transaction'.
transactionRollback :: Transaction -> IO ()
transactionRollback _ = return ()

--------------------------------------------------------------------------------
-- | Reads a single event from given stream.
readEvent :: Connection
          -> StreamName
          -> EventNumber
          -> ResolveLink
          -> Maybe Credentials
          -> IO (Async (ReadResult EventNumber Op.ReadEvent))
readEvent Connection{..} stream_id evtNum resLinkTos cred = do
    p <- newPromise
    let evt_num = eventNumberToInt64 evtNum
        res_link_tos = resolveLinkToBool resLinkTos
        op = Op.readEvent _settings (streamIdRaw stream_id) evt_num res_link_tos cred
    publishWith _exec (SubmitOperation p op)
    async (retrieve p)

--------------------------------------------------------------------------------
-- | When batch-reading a stream, this type-level function maps the result you
--   will have whether you read a regular stream or $all stream. When reading
--   a regular stream, some read-error can occur like the stream got deleted.
--   However read-error cannot occur when reading $all stream (because $all
--   cannot get deleted).
type family BatchResult t where
    BatchResult EventNumber = ReadResult EventNumber StreamSlice
    BatchResult Position    = AllSlice

--------------------------------------------------------------------------------
-- | Reads events from a stream forward.
readEventsForward :: Connection
                  -> StreamId t
                  -> t
                  -> Int32      -- ^ Batch size
                  -> ResolveLink
                  -> Maybe Credentials
                  -> IO (Async (BatchResult t))
readEventsForward conn = readEventsCommon conn Forward

--------------------------------------------------------------------------------
-- | Reads events from a stream backward.
readEventsBackward :: Connection
                   -> StreamId t
                   -> t
                   -> Int32      -- ^ Batch size
                   -> ResolveLink
                   -> Maybe Credentials
                   -> IO (Async (BatchResult t))
readEventsBackward conn = readEventsCommon conn Backward

--------------------------------------------------------------------------------
readEventsCommon :: Connection
                 -> ReadDirection
                 -> StreamId t
                 -> t
                 -> Int32
                 -> ResolveLink
                 -> Maybe Credentials
                 -> IO (Async (BatchResult t))
readEventsCommon Connection{..} dir streamId start cnt resLinkTos cred = do
    p <- newPromise
    let res_link_tos = resolveLinkToBool resLinkTos
        op =
            case streamId of
                StreamName{} ->
                    let name   = streamIdRaw streamId
                        evtNum = eventNumberToInt64 start in
                    Op.readStreamEvents _settings dir name evtNum cnt res_link_tos cred
                All ->
                    let Position c_pos p_pos = start in
                    Op.readAllEvents _settings c_pos p_pos cnt res_link_tos dir cred

    publishWith _exec (SubmitOperation p op)
    async (retrieve p)

--------------------------------------------------------------------------------
-- | Subscribes to a stream.
subscribe :: Connection
          -> StreamId t
          -> ResolveLink
          -> Maybe Credentials
          -> IO (RegularSubscription t)
subscribe Connection{..} stream resLinkTos cred =
    newRegularSubscription _exec stream resLnkTos cred
  where
    resLnkTos = resolveLinkToBool resLinkTos

--------------------------------------------------------------------------------
-- | Subscribes to a stream. If last checkpoint is defined, this will
--   'readStreamEventsForward' from that event number, otherwise from the
--   beginning. Once last stream event reached up, a subscription request will
--   be sent using 'subscribe'.
subscribeFrom :: Connection
              -> StreamId t
              -> ResolveLink
              -> Maybe t
              -> Maybe Int32 -- ^ Batch size
              -> Maybe Credentials
              -> IO (CatchupSubscription t)
subscribeFrom Connection{..} streamId resLinkTos lastChkPt batch cred =
    newCatchupSubscription _exec resLnkTos batch cred streamId $
        case streamId of
            StreamName{} -> fromMaybe streamStart lastChkPt
            All          -> fromMaybe positionStart lastChkPt
  where
    resLnkTos = resolveLinkToBool resLinkTos

--------------------------------------------------------------------------------
subscribeFromCommon :: Connection
                    -> ResolveLink
                    -> Maybe Int32
                    -> Maybe Credentials
                    -> StreamId t
                    -> t
                    -> IO (CatchupSubscription t)
subscribeFromCommon Connection{..} resLinkTos batch cred kind seed =
    newCatchupSubscription _exec resLnkTos batch cred kind seed
  where
    resLnkTos = resolveLinkToBool resLinkTos

--------------------------------------------------------------------------------
-- | Asynchronously sets the metadata for a stream.
setStreamMetadata :: Connection
                  -> StreamName
                  -> ExpectedVersion
                  -> StreamMetadata
                  -> Maybe Credentials
                  -> IO (Async WriteResult)
setStreamMetadata Connection{..} evt_stream exp_ver metadata cred = do
    p <- newPromise
    let name = streamIdRaw evt_stream
        op = Op.setMetaStream _settings name exp_ver cred metadata
    publishWith _exec (SubmitOperation p op)
    async (retrieve p)

--------------------------------------------------------------------------------
-- | Asynchronously gets the metadata of a stream.
getStreamMetadata :: Connection
                  -> StreamName
                  -> Maybe Credentials
                  -> IO (Async StreamMetadataResult)
getStreamMetadata Connection{..} evt_stream cred = do
    p <- newPromise
    let op = Op.readMetaStream _settings (streamIdRaw evt_stream) cred
    publishWith _exec (SubmitOperation p op)
    async (retrieve p)

--------------------------------------------------------------------------------
-- | Asynchronously create a persistent subscription group on a stream.
createPersistentSubscription :: Connection
                             -> Text
                             -> StreamName
                             -> PersistentSubscriptionSettings
                             -> Maybe Credentials
                             -> IO (Async (Maybe PersistActionException))
createPersistentSubscription Connection{..} grp stream sett cred = do
    p <- newPromise
    let op = Op.createPersist grp (streamIdRaw stream) sett cred
    publishWith _exec (SubmitOperation p op)
    async (persistAsync p)

--------------------------------------------------------------------------------
-- | Asynchronously update a persistent subscription group on a stream.
updatePersistentSubscription :: Connection
                             -> Text
                             -> StreamName
                             -> PersistentSubscriptionSettings
                             -> Maybe Credentials
                             -> IO (Async (Maybe PersistActionException))
updatePersistentSubscription Connection{..} grp stream sett cred = do
    p <- newPromise
    let op = Op.updatePersist grp (streamIdRaw stream) sett cred
    publishWith _exec (SubmitOperation p op)
    async (persistAsync p)

--------------------------------------------------------------------------------
-- | Asynchronously delete a persistent subscription group on a stream.
deletePersistentSubscription :: Connection
                             -> Text
                             -> StreamName
                             -> Maybe Credentials
                             -> IO (Async (Maybe PersistActionException))
deletePersistentSubscription Connection{..} grp stream cred = do
    p <- newPromise
    let op = Op.deletePersist grp (streamIdRaw stream) cred
    publishWith _exec (SubmitOperation p op)
    async (persistAsync p)

--------------------------------------------------------------------------------
-- | Asynchronously connect to a persistent subscription given a group on a
--   stream.
connectToPersistentSubscription :: Connection
                                -> Text
                                -> StreamName
                                -> Int32
                                -> Maybe Credentials
                                -> IO PersistentSubscription
connectToPersistentSubscription Connection{..} group stream bufSize cred =
    newPersistentSubscription _exec group stream bufSize cred

--------------------------------------------------------------------------------
persistAsync :: Callback (Maybe PersistActionException)
             -> IO (Maybe PersistActionException)
persistAsync = either throw return <=< tryRetrieve
