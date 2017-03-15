{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
--------------------------------------------------------------------------------
-- |
-- Module : Database.EventStore.Internal.Messaging
-- Copyright : (C) 2017 Yorick Laupa
-- License : (see the file LICENSE)
--
-- Maintainer : Yorick Laupa <yo.eight@gmail.com>
-- Stability : provisional
-- Portability : non-portable
--
--------------------------------------------------------------------------------
module Database.EventStore.Internal.Messaging
  ( Pub(..)
  , Sub(..)
  , subscribe
  , SubDecision(..)
  , asPub
  , asSub
  , Bus
  , newBus
  , busName
  , Message
  , toMsg
  , fromMsg
  ) where

--------------------------------------------------------------------------------
import Data.Typeable
import Data.Typeable.Internal

--------------------------------------------------------------------------------
import ClassyPrelude
import Data.Sequence (ViewL(..), viewl, (|>))

--------------------------------------------------------------------------------
data Message = forall a. Typeable a => Message a

--------------------------------------------------------------------------------
instance Show Message where
  show (Message a) = "Message: " <> show (typeOf a)

--------------------------------------------------------------------------------
toMsg :: Typeable a => a -> Message
toMsg = Message

--------------------------------------------------------------------------------
fromMsg :: Typeable a => Message -> Maybe a
fromMsg (Message a) = cast a

--------------------------------------------------------------------------------
class Pub p where
  publish :: Typeable a => p -> a -> IO ()

--------------------------------------------------------------------------------
data SubDecision
  = Continue
  | Done

--------------------------------------------------------------------------------
class Sub s where
  subscribeTo :: Typeable a => s -> (a -> IO SubDecision) -> IO ()

--------------------------------------------------------------------------------
subscribe :: (Sub s, Typeable a) => s -> (a -> IO ()) -> IO ()
subscribe s k = subscribeTo s $ \msg -> Continue <$ k msg

--------------------------------------------------------------------------------
data Publish = forall p. Pub p => Publish p

--------------------------------------------------------------------------------
instance Pub Publish where
  publish (Publish p) a = publish p a

--------------------------------------------------------------------------------
data Subscribe = forall p. Sub p => Subscribe p

--------------------------------------------------------------------------------
instance Sub Subscribe where
  subscribeTo (Subscribe p) a = subscribeTo p a

--------------------------------------------------------------------------------
asSub :: Sub s => s -> Subscribe
asSub = Subscribe

--------------------------------------------------------------------------------
asPub :: Pub p => p -> Publish
asPub = Publish

--------------------------------------------------------------------------------
data Type = Type TypeRep Fingerprint

--------------------------------------------------------------------------------
instance Show Type where
  show (Type rep _) = "type " <> show rep

--------------------------------------------------------------------------------
instance Eq Type where
  Type _ a == Type _ b = a == b

--------------------------------------------------------------------------------
instance Ord Type where
  compare (Type _ a) (Type _ b) = compare a b

--------------------------------------------------------------------------------
instance Hashable Type where
  hashWithSalt i (Type _ (Fingerprint b l)) = hashWithSalt i (b, l)

--------------------------------------------------------------------------------
data GetType
  = forall a. Typeable a => FromTypeable a
  | forall prx a. Typeable a => FromProxy (prx a)

--------------------------------------------------------------------------------
getType :: GetType -> Type
getType (FromTypeable a) = let t@(TypeRep fp _ _ _) = typeOf a in Type t fp
getType (FromProxy prx)  = let t@(TypeRep fp _ _ _) = typeRep prx in Type t fp

--------------------------------------------------------------------------------
type Callbacks = HashMap Type (Seq Callback)

--------------------------------------------------------------------------------
propagate :: Typeable a => a -> Seq Callback -> IO (Seq Callback)
propagate a = go mempty
  where
    go acc cur =
      case viewl cur of
        EmptyL -> return acc
        h@(Callback k) :< rest -> do
          let Just b = cast a
          decision <- k b
          case decision of
            Continue -> go (acc |> h) rest
            Done     -> go acc rest

--------------------------------------------------------------------------------
data Callback =
  forall a. Typeable a =>
  Callback { _callbackKey :: a -> IO SubDecision }

--------------------------------------------------------------------------------
instance Show Callback where
  show (Callback (_ :: a -> IO SubDecision)) =
    "Handle " <> show (typeRep (Proxy :: Proxy a))

--------------------------------------------------------------------------------
data Bus =
  Bus { busName       :: Text
      , _busCallbacks :: IORef Callbacks
      , _busQueue     :: TQueue Message
      , _busRunning   :: TVar Bool
      }

--------------------------------------------------------------------------------
messageType :: Type
messageType = getType (FromProxy (Proxy :: Proxy Message))

--------------------------------------------------------------------------------
newBus :: Text -> IO Bus
newBus name = Bus name <$> newIORef mempty
                       <*> newTQueueIO
                       <*> newTVarIO False

--------------------------------------------------------------------------------
worker :: Bus -> IO ()
worker b@Bus{..} = go
  where
    go = do

      let loop = do
            outcome <- atomically $ tryReadTQueue _busQueue
            case outcome of
              Nothing          -> return ()
              Just (Message a) -> do
                publishing b a
                loop

      loop
      atomically $ writeTVar _busRunning False

      allowedTo <- atomically $ do
        cleared <- isEmptyTQueue _busQueue
        running <- readTVar _busRunning

        if not cleared && not running
          then True <$ writeTVar _busRunning True
          else return False

      when allowedTo go

--------------------------------------------------------------------------------
instance Sub Bus where
  subscribeTo Bus{..} (k :: a -> IO SubDecision) =
    atomicModifyIORef' _busCallbacks $ \m ->
      let tpe  = getType (FromProxy (Proxy :: Proxy a))
          hdl  = Callback k
          next = alterMap $ \input ->
            case input of
              Nothing -> Just (singleton hdl)
              Just hs -> Just (snoc hs hdl) in
      (next tpe m, ())

--------------------------------------------------------------------------------
instance Pub Bus where
  publish b@Bus{..} a = do
    canFork <- atomically $ do
      writeTQueue _busQueue (toMsg a)
      running <- readTVar _busRunning

      unless running $
        writeTVar _busRunning True

      return $ not running

    when canFork $ do
      _ <- fork $ worker b
      return ()

--------------------------------------------------------------------------------
publishing :: Typeable a => Bus -> a -> IO ()
publishing Bus{..} a = do
  cs <- readIORef _busCallbacks
  let tpe = getType (FromTypeable a)

  act1 <- traverse (propagate a) (lookup tpe cs)
  act2 <- if tpe == messageType
            then return Nothing
            else traverse (propagate (toMsg a)) (lookup messageType cs)

  for_ act1 $ \callbacks ->
    atomicModifyIORef' _busCallbacks $ \m ->
      (insertMap tpe callbacks m, ())

  for_ act2 $ \callbacks ->
    atomicModifyIORef' _busCallbacks $ \m ->
      (insertMap messageType callbacks m, ())
