{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
--------------------------------------------------------------------------------
-- |
-- Module : Test.Integration.Tests
-- Copyright : (C) 2017 Yorick Laupa
-- License : (see the file LICENSE)
--
-- Maintainer : Yorick Laupa <yo.eight@gmail.com>
-- Stability : provisional
-- Portability : non-portable
--
-- Gathers all EventStore operations tests.
--------------------------------------------------------------------------------
module Test.Integration.Tests (tests) where

--------------------------------------------------------------------------------
import ClassyPrelude

--------------------------------------------------------------------------------
import Data.Aeson
import Data.DotNet.TimeSpan
import Data.UUID hiding (null)
import Data.UUID.V4
import Test.Tasty
import Test.Tasty.HUnit

--------------------------------------------------------------------------------
import Database.EventStore

--------------------------------------------------------------------------------
tests :: Connection -> [TestTree]
tests conn =
    [ testCase "Write event" $ writeEventTest conn
    , testCase "Read event" $ readEventTest conn
    , testCase "Delete stream" $ deleteStreamTest conn
    , testCase "Transaction" $ transactionTest conn
    , testCase "Read forward" $ readStreamEventForwardTest conn
    , testCase "Read backward" $ readStreamEventBackwardTest conn
    , testCase "Real $all forward" $ readAllEventsForwardTest conn
    , testCase "Real $all backward" $ readAllEventsBackwardTest conn
    , testCase "Subscription test" $ subscribeTest conn
    , testCase "Subscription from test" $ subscribeFromTest conn
    , testCase "Subscription from catchup not blocking" $
          subscribeFromNoStreamTest conn
    , testCase "Set Stream Metadata" $ setStreamMetadataTest conn
    , testCase "Get Stream Metadata" $ getStreamMetadataTest conn
    , testCase "Create persistent sub" $ createPersistentTest conn
    , testCase "Update persistent sub" $ updatePersistentTest conn
    , testCase "Delete persistent sub" $ deletePersistentTest conn
    , testCase "Connect persistent sub" $ connectToPersistentTest conn
    , testCase "MaxAge metadata test" $ maxAgeTest conn
    , testCase "Shutdown connection" $ shutdownTest conn
    ]


--------------------------------------------------------------------------------
freshStreamId :: IO StreamName
freshStreamId = fmap (StreamName . toText) nextRandom

--------------------------------------------------------------------------------
writeEventTest :: Connection -> IO ()
writeEventTest conn = do
    let js  = object [ "baz" .= True ]
        evt = createEvent "foo" Nothing $ withJson js

    stream <- freshStreamId
    as <- sendEvent conn stream anyVersion evt
    _  <- waitAsync as
    return ()

--------------------------------------------------------------------------------
readEventTest :: Connection -> IO ()
readEventTest conn = do
    stream <- freshStreamId

    let js  = object [ "baz" .= True ]
        evt = createEvent "foo" Nothing $ withJson js
    as <- sendEvent conn stream anyVersion evt
    _  <- waitAsync as
    bs <- readEvent conn stream 0 False
    rs <- waitAsync bs
    case rs of
        ReadSuccess re ->
            case re of
                ReadEvent _ _ revt ->
                    case resolvedEventDataAsJson revt of
                        Just js_evt ->
                            assertEqual "event should match" js js_evt
                        Nothing -> fail "Error when retrieving recorded data"
                _ -> fail "Event not found"
        e -> fail $ "Read failure: " ++ show e

--------------------------------------------------------------------------------
deleteStreamTest :: Connection -> IO ()
deleteStreamTest conn = do
    stream <- freshStreamId
    let js  = object [ "baz" .= True ]
        evt = createEvent "foo" Nothing $ withJson js
    _ <- sendEvent conn stream anyVersion evt >>= waitAsync
    _ <- deleteStream conn stream anyVersion Nothing
    return ()

--------------------------------------------------------------------------------
transactionTest :: Connection -> IO ()
transactionTest conn = do
    stream <- freshStreamId
    let js  = object [ "baz" .= True ]
        evt = createEvent "foo" Nothing $ withJson js
    t  <- startTransaction conn stream anyVersion >>= waitAsync
    _  <- transactionWrite t [evt] >>= waitAsync
    rs <- readEvent conn stream 0 False >>= waitAsync
    case rs of
        ReadNoStream -> return ()
        e -> fail $ "transaction-test stream is supposed to not exist "
                  ++ show e
    _   <- transactionCommit t >>= waitAsync
    rs2 <- readEvent conn stream 0 False >>= waitAsync
    case rs2 of
        ReadSuccess re ->
            case re of
                ReadEvent _ _ revt ->
                    case resolvedEventDataAsJson revt of
                        Just js_evt ->
                            assertEqual "event should match" js js_evt
                        Nothing -> fail "Error when retrieving recorded data"
                _ -> fail "Event not found"
        e -> fail $ "Read failure: " ++ show e

--------------------------------------------------------------------------------
readStreamEventForwardTest :: Connection -> IO ()
readStreamEventForwardTest conn = do
    stream <- freshStreamId
    let jss = [ object [ "baz" .= True]
              , object [ "foo" .= False]
              , object [ "bar" .= True]
              ]
        evts = fmap (createEvent "foo" Nothing . withJson) jss
    _  <- sendEvents conn stream anyVersion evts >>= waitAsync
    rs <- readStreamEventsForward conn stream 0 10 False >>= waitAsync
    case rs of
        ReadSuccess sl -> do
            let jss_evts = catMaybes $ fmap resolvedEventDataAsJson
                                     $ sliceEvents sl
            assertEqual "Events should be equal" jss jss_evts
        e -> fail $ "Read failure: " ++ show e

--------------------------------------------------------------------------------
readStreamEventBackwardTest :: Connection -> IO ()
readStreamEventBackwardTest conn = do
    let jss = [ object [ "baz" .= True]
              , object [ "foo" .= False]
              , object [ "bar" .= True]
              ]
        evts = fmap (createEvent "foo" Nothing . withJson) jss
    _  <- sendEvents conn "read-backward-test" anyVersion evts >>= waitAsync
    rs <- readStreamEventsBackward conn "read-backward-test" 2 10 False >>= waitAsync
    case rs of
        ReadSuccess sl -> do
            let jss_evts = catMaybes $ fmap resolvedEventDataAsJson
                                     $ sliceEvents sl
            assertEqual "Events should be equal" (reverse jss) jss_evts
        e -> fail $ "Read failure: " ++ show e

--------------------------------------------------------------------------------
readAllEventsForwardTest :: Connection -> IO ()
readAllEventsForwardTest conn = do
    sl <- readAllEventsForward conn positionStart 3 False >>= waitAsync
    assertEqual "Events is not empty" False (null $ sliceEvents sl)

--------------------------------------------------------------------------------
readAllEventsBackwardTest :: Connection -> IO ()
readAllEventsBackwardTest conn = do
    sl <- readAllEventsBackward conn positionEnd 3 False >>= waitAsync
    assertEqual "Events is not empty" False (null $ sliceEvents sl)

--------------------------------------------------------------------------------
subscribeTest :: Connection -> IO ()
subscribeTest conn = do
    stream <- freshStreamId

    let jss = [ object [ "baz" .= True]
              , object [ "foo" .= False]
              , object [ "bar" .= True]
              ]
        evts = fmap (createEvent "foo" Nothing . withJson) jss
    sub  <- subscribe conn stream False
    _    <- waitConfirmation sub
    _    <- sendEvents conn stream anyVersion evts >>= waitAsync
    let loop 3 = return []
        loop i = do
            e <- nextEvent sub
            fmap (resolvedEventDataAsJson e:) $ loop (i+1)

    nxt_js <- loop (0 :: Int)
    assertEqual "Events should be equal" jss (catMaybes nxt_js)
    unsubscribe sub
    let action = do
            _ <- nextEvent sub
            return False
    res <- catch action $ \(_ :: SubscriptionClosed) -> return True
    assertBool "Should have raised an exception" res

--------------------------------------------------------------------------------
subscribeFromTest :: Connection -> IO ()
subscribeFromTest conn = do
    stream <- freshStreamId

    let jss = [ object [ "1" .= (1 :: Int)]
              , object [ "2" .= (2 :: Int)]
              , object [ "3" .= (3 :: Int)]
              ]
        jss2 = [ object [ "4" .= (4 :: Int)]
               , object [ "5" .= (5 :: Int)]
               , object [ "6" .= (6 :: Int)]
               ]
        alljss = jss ++ jss2
        evts   = fmap (createEvent "foo" Nothing . withJson) jss
        evts2  = fmap (createEvent "foo" Nothing . withJson) jss2
    _   <- sendEvents conn stream anyVersion evts >>= waitAsync
    sub <- subscribeFrom conn stream False Nothing (Just 1)
    _   <- waitConfirmation sub
    _   <- sendEvents conn stream anyVersion evts2 >>= waitAsync

    let loop [] = do
            m <- nextEventMaybe sub
            case m of
                Just _  -> fail "should not have more events at the point."
                Nothing -> return ()
        loop (x:xs) = do
            evt <- nextEvent sub
            case recordedEventDataAsJson $ resolvedEventOriginal evt of
                Just e | e == x    -> loop xs
                       | otherwise -> fail "Out of order event's appeared."
                _ -> fail "Can't deserialized event"

    loop alljss
    unsubscribe sub
    waitUnsubscribeConfirmed sub
    let action = do
            _ <- nextEvent sub
            return False
    res <- catch action $ \(_ :: SubscriptionClosed) -> return True
    assertBool "Should have raised an exception" res

--------------------------------------------------------------------------------
data SubNoStreamTest
  = SubNoStreamTestSuccess
  | SubNoStreamTestTimeout
  deriving (Eq, Show)

--------------------------------------------------------------------------------
secs :: Int
secs = 1000 * 1000

--------------------------------------------------------------------------------
subscribeFromNoStreamTest :: Connection -> IO ()
subscribeFromNoStreamTest conn = do
  stream <- freshStreamId
  sub <- subscribeFrom conn stream False Nothing Nothing
  let loop [] = do
          m <- nextEventMaybe sub
          case m of
              Just _  -> fail "should not have more events at the point."
              Nothing -> return ()
      loop (x:xs) = do
          evt <- nextEvent sub
          case recordedEventDataAsJson $ resolvedEventOriginal evt of
              Just e | e == x    -> loop xs
                     | otherwise -> fail "Out of order event's appeared."
              _ -> fail "Can't deserialized event"

      subAction = do
          waitTillCatchup sub
          let jss = [ object [ "1" .= (1 :: Int)]
                    , object [ "2" .= (2 :: Int)]
                    , object [ "3" .= (3 :: Int)]
                    ]

              evts = fmap (createEvent "foo" Nothing . withJson) jss

          _ <- sendEvents conn stream anyVersion evts >>= waitAsync
          loop jss
          return SubNoStreamTestSuccess
      timeout = do
          threadDelay (10 * secs)
          return SubNoStreamTestTimeout

  res <- race subAction timeout
  case res of
    Left r -> assertEqual "Wrong test result" SubNoStreamTestSuccess r
    Right r -> assertEqual "Wrong test result" SubNoStreamTestSuccess r

--------------------------------------------------------------------------------
setStreamMetadataTest :: Connection -> IO ()
setStreamMetadataTest conn = do
    stream <- freshStreamId
    let metadata = buildStreamMetadata $ setCustomProperty "foo" (1 :: Int)
    _ <- setStreamMetadata conn stream anyVersion metadata >>= waitAsync
    return ()

--------------------------------------------------------------------------------
getStreamMetadataTest :: Connection -> IO ()
getStreamMetadataTest conn = do
    stream <- freshStreamId
    let metadata = buildStreamMetadata $ setCustomProperty "foo" (1 :: Int)
    _ <- setStreamMetadata conn stream anyVersion metadata >>= waitAsync
    r <- getStreamMetadata conn stream >>= waitAsync
    case r of
        StreamMetadataResult _ _ m ->
            case getCustomProperty m "foo" of
                Just i -> assertEqual "Should have equal value" (1 :: Int) i
                _      -> fail "Can't find foo property"
        _ -> fail $ "Stream " <> show stream <> " doesn't exist"

--------------------------------------------------------------------------------
createPersistentTest :: Connection -> IO ()
createPersistentTest conn = do
    let def = defaultPersistentSubscriptionSettings
    stream <- freshStreamId
    r <- createPersistentSubscription conn "group" stream def >>= waitAsync
    case r of
        Nothing -> return ()
        Just e  -> fail $ "Exception arised: " ++ show e

--------------------------------------------------------------------------------
updatePersistentTest :: Connection -> IO ()
updatePersistentTest conn = do
    let def = defaultPersistentSubscriptionSettings
    stream <- freshStreamId
    _ <- createPersistentSubscription conn "group" stream def >>= waitAsync
    r <- updatePersistentSubscription conn "group" stream def >>= waitAsync
    case r of
        Nothing -> return ()
        Just e  -> fail $ "Exception arised: " ++ show e

--------------------------------------------------------------------------------
deletePersistentTest :: Connection -> IO ()
deletePersistentTest conn = do
    let def = defaultPersistentSubscriptionSettings
    stream <- freshStreamId
    _ <- createPersistentSubscription conn "group" stream def >>= waitAsync
    r <- deletePersistentSubscription conn "group" stream >>= waitAsync
    case r of
        Nothing -> return ()
        Just e  -> fail $ "Exception arised: " ++ show e

--------------------------------------------------------------------------------
connectToPersistentTest :: Connection -> IO ()
connectToPersistentTest conn = do
    let def = defaultPersistentSubscriptionSettings
        js1 = object ["baz" .= True]
        js2 = object ["foo" .= True]
        jss  = [ js1
               , js2
               ]
        evts = fmap (createEvent "foo" Nothing . withJson) jss
    stream <- freshStreamId
    _   <- createPersistentSubscription conn "group" stream def >>= waitAsync
    _   <- sendEvents conn stream anyVersion evts >>= waitAsync
    sub <- connectToPersistentSubscription conn "group" stream 1
    _   <- waitConfirmation sub
    r   <- nextEvent sub
    case resolvedEventDataAsJson r of
        Just js_evt -> assertEqual "event 1 should match" js1 js_evt
        _           -> fail "Deserialization error"

    notifyEventsProcessed sub [resolvedEventOriginalId r]

    r2 <- nextEvent sub
    case resolvedEventDataAsJson r2 of
        Just js_evt -> assertEqual "event 2 should match" js2 js_evt
        _           -> fail "Deserialization error"

    notifyEventsProcessed sub [resolvedEventOriginalId r2]

    unsubscribe sub
    let action = do
            _ <- nextEvent sub
            return False
    res <- catch action $ \(_ :: SubscriptionClosed) -> return True
    assertBool "Should have raised an exception" res

--------------------------------------------------------------------------------
maxAgeTest :: Connection -> IO ()
maxAgeTest conn = do
    let timespan = fromDays 1
        metadata = buildStreamMetadata $ setMaxAge timespan
        evt = createEvent "foo" Nothing
              $ withJson (object ["type" .= (3 :: Int)])
    stream <- freshStreamId
    _ <- sendEvent conn stream anyVersion evt >>= waitAsync
    _ <- setStreamMetadata conn stream anyVersion metadata >>= waitAsync
    r <- getStreamMetadata conn stream >>= waitAsync
    case r of
        StreamMetadataResult _ _ m ->
            assertEqual "Should have equal timespan" (Just timespan)
            (streamMetadataMaxAge m)
        _ -> fail $ "Stream " <> show stream <> " doesn't exist"

--------------------------------------------------------------------------------
shutdownTest :: Connection -> IO ()
shutdownTest conn = do
    stream <- freshStreamId
    let js     = object ["baz" .= True]
        evt    = createEvent "foo" Nothing $ withJson js
        action = do
            _ <- sendEvent conn stream anyVersion evt
            return False
    shutdown conn
    waitTillClosed conn
    res <- catch action $ \(_ :: SomeException) -> return True

    assertBool "Should have raised an exception" res
