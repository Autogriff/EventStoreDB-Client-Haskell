0.14.0.1
----------
* Fix subscription deadlock on connection drop.
* Fix subscription catchup state tracking on connection drop.
* Fix internal connection dispose lock implementation.
* Bump `aeson` version.

0.14.0.0
--------
* Fix deadlock issues in subscription code.
* Improve cluster connection fiability.
* Internal refactoring.
* Typeful `EventType`

0.13.1.7
--------
* Report stream name when facing a 'Stream not found' error from the server on catchup subscription.
* Prevent the driver from deadlocking when asking for catchup subscription on a stream that doesn't exist.

0.13.1.6
--------
* Fix a deadlock on user side when asking a catchup subscription on a stream that doesn't exist.

0.13.1.5
--------
* Fix an internal connection bug.

0.13.1.4
--------
* Bump `aeson` version.
* Internal connection refactoring.

0.13.1.3
--------
* Bump `http-client` version.

0.13.1.2
--------
* Restrain `http-client` package version.

0.13.1.1
--------
* Typo on `streamExists` implementation.

0.13.1.0
--------
* Add `streamExists` `ExpectedVersion` smart constructor.

0.13.0.1
--------
* Bump protobuf version

0.13.0.0
--------
* Implement SSL Connection
* Implement `waitConfirmation` function

0.12.0.0
--------
* Quit using internal .NET TimeSpan for dotnet-timespan TimeSpan

0.11.0.0
--------
* Implement Cluster connection.
* Domain can be used to connect to a server instance.

0.10.0.2
--------
* Bump aeson version.

0.10.0.1
--------
* Bump async version.


0.10.0.0
--------
* Fix $maxAge and $cacheControl TimeSpan metadata serialization.
* Fix `timeSpanFrom*` functions.
* Implement `timeSpanTotalDays`, `timeSpanTotalHours`, `timeSpanTotalMinutes` and `timeSpanTotalSeconds`.
* Add `withBinary` and `withBinaryAndMetadata`.
* Remove useless `TimeSpan` `ToJSON` and `FromJSON` instances.
* Drop `attoparsec` dependency.

0.9.1.3
-------
* Increase cereal upper bound to <0.6

0.9.1.2
-------
* Increase aeson upper bound to <0.11

0.9.1.1
-------
* Fix stackage integration.

0.9.1.0
-------
* Introduce convinient persistent subscription functions.
* Add multi GHC version testing.

0.9.0.0
-------
* Rewrite entirely the internals.
* Implement integration tests.
* Rename every `ExpectedVersion` smart constructors.
* Improve internal and public documentation.
* Improve failure reports when the connection dropped.
* Implement more robust internal connection.

0.8.0.0
-------
* Implement competing consumers.
* Expose an uniform API among all kind of subscriptions.
* Rewrite internal subscription management.
* Add missing `Eq` or `Show` instances for exposed datatypes.
* Add `streamMetadataCustomPropertyValue` and `streamMetadataCustomProperty`.
* Add logging capability.

0.7.2.1
-------
* Fix compilation issue

0.7.2.0
-------
* Add `setStreamMetadata`
* Add `getStreamMetadata`

0.7.1.0
-------
* Internal connection changes
* Allow creating an event with an existing ID

0.7.0.1
-------
* Tight package channnel to connection instance in order to prevent loss on connection drops.
* `Connection` has asynchronous operation for real now.

0.7.0.0
-------
* Fix date conversion. `recordedEventCreateEpoch` is no longer exposed.
* Add `waitTillCatchup` and `hasCaughtUp` functions.
* Add `exactStream` `ExpectedVersion` smart constructor. As the result,
`ExpectedVersion` constructors are no longer exposed. You have to use
`anyStream`, `noStream`, `emptyStream` or `exactStream` instead.

0.6.0.1
-------
No changes

0.6.0.0
-------
* Support `keepRetrying` reconnection strategy.
